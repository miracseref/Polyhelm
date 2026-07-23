# Polyhelm

A Dynamic Island for your coding agents. Watch every Claude Code session from the
notch, approve tool calls, answer questions, and jump to the right terminal tab.

## Install

1. Drag **Polyhelm.app** to `/Applications`
2. Open it

If macOS says the app "cannot be opened because the developer cannot be
verified", it is unsigned — **right-click the app → Open**, then confirm. You
only do this once. Or, from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Polyhelm.app
```

## Set up

Polyhelm starts empty because it doesn't know about your agents yet.

Menu bar icon (top right) → **Install Claude Code hooks…**

That writes `~/.polyhelm/hook.sh` and adds hook entries to
`~/.claude/settings.json`. Your existing settings are backed up first. Start a
new Claude Code session in any terminal and it appears in the notch.

Requires macOS 14+ and `jq` (ships with macOS 15+; otherwise `brew install jq`).

## Using it

- **Hover the notch** to expand. **⌥⌘Space** opens it from anywhere.
- **Sessions tab** — every running agent, what it's doing, and its state. Click a
  row to target it, then type in the bar at the bottom to send it a prompt.
- A session **blocked on a question** gets an inline answer box with one-tap
  `yes` / `no` / `continue`.
- **Usage tab** — token spend and, where the harness publishes it, your real
  quota percentage.
- Click the **arrow** on a row to jump to that session's terminal tab.

### Approvals in the notch (optional, off by default)

Menu bar → **Approvals in the notch**. Tool calls then pause and wait for
Allow / Deny from the notch instead of the terminal. It fails safe: if you don't
answer within 45 seconds, or Polyhelm isn't running, Claude Code just shows its
normal prompt.

## Permissions it will ask for

- **Automation** — to focus a terminal tab and type into it. Required for the
  jump and prompt features; everything else works without it.

That's all. No network access beyond `127.0.0.1`, no account, no telemetry.

## Privacy

Polyhelm reads your local agent logs (`~/.claude/projects`, `~/.codex/sessions`)
to count token usage, and listens on `127.0.0.1:8787` for hook events. Nothing
leaves your machine.

## Uninstall

Menu bar → **Remove hooks…**, then delete the app and `~/.polyhelm`.
