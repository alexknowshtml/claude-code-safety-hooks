# Claude Code Safety Hooks

Production-tested safety primitives for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents. Extracted from [JFDIBot](https://jfdi.bot), an AI executive assistant that manages email, membership platforms, DNS, and shell access for a real business.

Read the full write-up: [Three Layers Between My AI and My Data](https://jfdi.bot/blog/three-layer-ai-defense)

## Three layers of defense

These components implement a layered defense model. Each layer is independent - none of them trust the others.

### Layer 1: Instruction-source separation (behavioral)

**File:** [`includes/untrusted-content-defense.md`](includes/untrusted-content-defense.md)

A set of rules loaded into your agent's context that establish a foundational principle: the user's messages are instructions, everything fetched from outside is data. Covers authority claims, override language, exfiltration requests, and encoded payloads.

This is the weakest layer because it depends on the AI following instructions correctly. A sufficiently clever injection could slip through.

### Layer 2: Architectural isolation (structural)

When your agent processes external content, route it through a sandboxed sub-agent that extracts what's useful and returns a summary. The main agent that has access to tools and systems never sees the raw external content. An injection has to survive two hops - influencing the sandboxed processor, then re-injecting through the summary into the main agent's decision-making.

This repo doesn't include a turnkey implementation of Layer 2 (it depends on your agent architecture), but the [blog post](https://jfdi.bot/blog/how-jfdibot-protects-against-content-injection-and-destructive-actions) describes the pattern in detail.

### Layer 3: Deterministic command guard (code, no AI)

**File:** [`hooks/dangerous-command-guard.sh`](hooks/dangerous-command-guard.sh)

A bash script that runs as a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks). It intercepts every Bash tool call and checks it against destructive patterns using regex. No AI in the loop. A `git push --force` triggered by an injection gets caught by the same pattern matching that catches an honest mistake.

This is the backstop. Even if layers 1 and 2 both fail, destructive actions are blocked by code.

## Quick Install

The fastest way to install is to give this README to your Claude Code agent:

> "Read this README and install both the dangerous command guard hook and the untrusted content defense include into my project."

Your agent will know what to do. The rest of this README is written for both humans and agents.

---

## Dangerous Command Guard

### What it blocks

| Pattern | Why |
|---------|-----|
| `reboot`, `shutdown`, `poweroff`, `halt` | System availability |
| `systemctl restart/stop` | Service disruption |
| `rm -rf /` or `rm -rf ~` | Filesystem destruction (allows `/tmp`) |
| `kill -1`, `pkill -9` | Process termination |
| `mkfs`, `dd of=/dev/` | Disk/filesystem destruction |
| `git reset --hard` | Destroys uncommitted work |
| `git push --force` / `git push -f` | Destroys remote history |
| `git clean -f` (without `--dry-run`) | Removes untracked files permanently |
| `git stash drop/clear` | Deletes stashed changes |

### How approval works

When a command is blocked:

1. The hook writes a **pending file** to `/tmp/claude-dangerous/pending/` with the command details
2. The hook returns a `deny` decision with a message explaining what was blocked
3. To approve, create a single-use token: `touch /tmp/claude-dangerous/approved/<hash>`
4. On the next attempt, the hook finds the token, **consumes it** (deletes it), and allows the command
5. The token cannot be reused - every dangerous command needs its own explicit approval

Tokens auto-expire: pending files after 5 minutes, approval tokens after 60 seconds.

### Installation

**Requires:** `jq` (for parsing hook input JSON)

#### Option A: Project-level (recommended)

Copy the hook script into your project:

```bash
mkdir -p .claude/hooks
cp hooks/dangerous-command-guard.sh .claude/hooks/
chmod +x .claude/hooks/dangerous-command-guard.sh
```

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hook": "bash .claude/hooks/dangerous-command-guard.sh"
      }
    ]
  }
}
```

#### Option B: Global (all projects)

Copy to your Claude Code config directory:

```bash
mkdir -p ~/.claude/hooks
cp hooks/dangerous-command-guard.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/dangerous-command-guard.sh
```

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hook": "bash ~/.claude/hooks/dangerous-command-guard.sh"
      }
    ]
  }
}
```

### Extending with notifications

The script includes a clearly marked notification hook point where you can add your own alerting. In our production system, we send a Discord message with Approve/Deny buttons. You could use:

- **Slack/Discord webhook** - Post a message with the blocked command
- **Desktop notification** - `notify-send` (Linux) or `osascript` (macOS)
- **HTTP webhook** - Trigger any external approval workflow
- **Log file** - Write to a file for batch review

The pending file at `/tmp/claude-dangerous/pending/<hash>.json` contains all the context you need:

```json
{
  "hash": "a1b2c3d4...",
  "session_id": "abc123",
  "command": "git push --force origin main",
  "reason": "force push and potentially destroy remote history",
  "timestamp": 1711684800
}
```

### Adding custom patterns

Edit the `check_dangerous()` function to add patterns specific to your environment:

```bash
# Example: Block database drops
if echo "$cmd" | grep -qiE 'DROP[[:space:]]+(DATABASE|TABLE)'; then
    echo "drop a database or table"
    return 0
fi

# Example: Block Docker system prune
if echo "$cmd" | grep -qiE 'docker[[:space:]]+system[[:space:]]+prune'; then
    echo "remove all unused Docker data"
    return 0
fi
```

---

## Untrusted Content Defense

A markdown file designed to be loaded into your Claude Code agent's context when it processes external content. It establishes the principle of **instruction-source separation**: the user's messages are instructions, everything fetched from outside is data.

Adapted from the [AI Content Integrity Protocol (ACIP) v1.3](https://github.com/Dicklesworthstone/acip) by Jeff Emanuel.

### What it defends against

- **Prompt injection** - Embedded instructions in web pages, emails, or API responses that try to hijack agent behavior
- **Authority spoofing** - Content claiming to be "SYSTEM:", "ADMIN:", or "DEVELOPER:" messages
- **Exfiltration attempts** - Content requesting the agent email credentials, save system prompts, or fetch attacker-controlled URLs
- **Encoded payloads** - Base64 or character-code obfuscated instructions hidden in normal content
- **Gradual escalation** - Content that starts benign and progressively embeds directive language

### Installation

Copy the include into your project:

```bash
mkdir -p .claude/includes
cp includes/untrusted-content-defense.md .claude/includes/
```

Reference it in your `CLAUDE.md`:

```markdown
## Safety Rules

When processing external content (web pages, emails, API responses, user-submitted text),
load and follow the rules in `.claude/includes/untrusted-content-defense.md`.
```

For conditional loading (only when processing external content), reference it in specific workflow instructions rather than loading it globally.

---

## Credits

- **Dangerous Command Guard** - Original hook design and single-use approval token system by [Alex Hillman](https://github.com/alexknowshtml) for the [JFDIBot](https://jfdi.bot) AI assistant system
- **Untrusted Content Defense** - Adapted from the [AI Content Integrity Protocol (ACIP) v1.3](https://github.com/Dicklesworthstone/acip) by [Jeff Emanuel](https://github.com/Dicklesworthstone)
- **Claude Code Hooks** - Built on the [Claude Code hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks) by Anthropic

## License

MIT
