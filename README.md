# Polyhelm

A Dynamic Island for your coding agents. Native Swift, macOS, no Electron.

Collapsed, it's a black bar hugging the notch showing a dot per running session.
Hover and it drops into a panel where you can see what every agent is doing,
approve or deny tool calls without leaving your editor, and click a session to
jump to the exact terminal tab it's running in.

## Sharing it

```bash
./Scripts/package.sh          # -> build/dist/Polyhelm.zip + README
```

The script signs with a **Developer ID Application** certificate and notarizes
when both that and a `notarytool` keychain profile exist, and tells you exactly
what is missing when they don't. It will not pretend an unsigned build is
distributable.

Note that an **Apple Development** certificate is not enough — those validate
only on machines registered to your account. Without a Developer ID, recipients
get a Gatekeeper rejection and must right-click → Open once, or:

```bash
xattr -dr com.apple.quarantine /Applications/Polyhelm.app
```

To notarize properly you need the paid Apple Developer Program, then:

```bash
xcrun notarytool store-credentials notarytool \
  --apple-id <you> --team-id <TEAMID> --password <app-specific-password>
```

`Scripts/RECIPIENT-README.md` ships alongside the zip and covers install, setup
and permissions from the recipient's side.

Signed builds use the hardened runtime, which is why
`Scripts/polyhelm.entitlements` declares `apple-events` — without it, terminal
jump and prompt sending fail silently in a notarized build.

## Build

```bash
./Scripts/build-app.sh release      # builds + installs to /Applications
open -a Polyhelm
```

Debug build lands in `./build/Polyhelm.app` instead:

```bash
./Scripts/build-app.sh
```

Requires the Swift 6 toolchain (ships with Xcode / Command Line Tools) and macOS 14+.

## Which harnesses appear

| Harness | Sessions | Usage |
|---|---|---|
| **Claude Code** | yes, via hooks (push) | tokens, measured locally |
| **Codex** | yes, by watching `~/.codex/sessions` (poll) | real server quota % |
| Gemini / Cursor / opencode | no | probed; nothing readable |

Claude Code can push events through its hook system. Codex has no hooks, but it
appends a JSONL rollout per session containing the working directory, the model,
and `task_started` / `task_complete` events — enough to reconstruct state without
Codex cooperating. It is read-only polling on an 8s timer, mtime-filtered and
cached, and it never writes to Codex's files.

[Conductor](#conductor) is a launcher, not a harness of its own: the agents it
runs are ordinary Claude Code and Codex sessions and appear branded as such.

Codex records no tty, so those sessions can't be jumped to or typed into; the UI
hides both affordances rather than offering something that would do nothing.

```bash
.build/arm64-apple-macosx/debug/Polyhelm --codex-sessions 60   # what it sees
```

## Conductor

[Conductor](https://conductor.build) runs many Claude Code and Codex agents at
once, each in its own git worktree under `~/conductor/workspaces/`. It is **not a
separate harness** — those are ordinary Claude Code and Codex sessions, so they
show up in the island with the same marks and states as any other, just labelled
by their branch. The only Conductor-specific thing is *where the row jumps to*.

Conductor exposes no hooks, and it runs its agents with no controlling terminal,
so neither the hook pipeline nor a tty could see them on their own. But
everything the UI needs is already in the app's own database at
`~/Library/Application Support/com.conductor.app/conductor.db`. Polyhelm opens it
**read-only** on an 8s timer and reads one row per active (non-archived)
workspace, joining the session to its workspace and repo:

| Row shows | From |
|---|---|
| the **branch** as the label | `workspaces.branch` |
| the agent mark (Claude Code / Codex) | `sessions.agent_type` |
| model + context fill | `sessions.model / context_used_percent` |
| working / done / error | `sessions.status`, folded onto the island's states |

It never writes, never takes a write lock, and touches nothing else Conductor
owns — SQLite's WAL mode lets the read run concurrently with Conductor's writes.
A workspace untouched for 30 minutes drops off, so the list stays to what you are
actually working in rather than the hundreds of archived worktrees on disk.

There is no terminal to type into, so instead of a compose bar these rows get a
**jump**: clicking the row (or *Open in Conductor* on a question) brings the
Conductor app to the front. Dedup is automatic — if you also run the Claude Code
hooks, or a Conductor Codex agent also writes a rollout under `~/.codex`, the
session is recognised by its worktree path and shown once here, not twice.

```bash
.build/arm64-apple-macosx/debug/Polyhelm --conductor-sessions 120   # what it sees
```

## Wiring it to Claude Code

Menu bar icon → **Install Claude Code hooks…**

That writes `~/.polyhelm/hook.sh` and registers it in `~/.claude/settings.json`
(your existing settings are backed up to `settings.polyhelm-backup-<date>.json`
first). Start a new Claude Code session and it shows up in the notch.

The hook forwards `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`Notification`, `Stop`, `SubagentStop` and `SessionEnd`. It only ever talks to
`127.0.0.1:8787` — nothing leaves the machine, and there are no accounts or
telemetry.

### Approvals in the notch

Off by default, because it changes where permission prompts appear. Turn it on
from the menu bar (**Approvals in the notch**) — the hook entries rewrite
themselves, no JSON editing.

Now a tool call blocks in the terminal while an Allow / Deny card appears in the
notch. It's designed to fail safe in every direction:

| Situation | What happens |
|---|---|
| You click Allow / Deny | Decision goes straight back to Claude Code |
| Nobody answers within 45s | Card clears, Claude Code shows its normal prompt |
| You deny with a note | The note goes back as `permissionDecisionReason` |
| Polyhelm isn't running | `curl` fails, hook exits 0, nothing changes |
| `jq` missing, bad JSON, empty stdin | Hook exits 0, nothing changes |

The hook can never block a session or crash it — worst case, you get stock
Claude Code behavior.

## Sending a prompt from the notch

The expanded panel has a compose bar. Click a session to target it, type, hit ⏎.

There is no API to push text into a running Claude Code process, so this types
into the session's terminal the way you would:

- **iTerm2** — `write text` to the matched session
- **Terminal.app** — `do script … in tab`
- **tmux** — `send-keys` to the pane (wins over the host emulator)
- **WezTerm / kitty** — `send-text` to the matched pane/window
- **anything else** — copies to the clipboard and focuses the terminal, one paste away

The message is always passed as a single escaped argument, never concatenated
into a shell command, so `;` and backticks get typed rather than executed.
Sessions with no terminal (the Claude Code desktop app) can't be targeted.

## Usage across harnesses

The usage chip in the header covers every harness it can find, and it is careful
about the difference between two very different numbers:

| Harness | What it reports | Source |
|---|---|---|
| **Codex** | real `used_percent` of your plan's window, with reset time and plan tier | the server's own rate-limit response, recorded in `~/.codex/sessions/**` |
| **Claude Code** | tokens and messages in the current 5-hour block | measured from `~/.claude/projects/**` — no server quota is stored locally |
| **Gemini / Cursor / opencode** | "installed, nothing readable" | probed; they keep no parsable usage logs |

Only Codex can show a percentage, because it is the only one that persists what
the server said. Claude Code's transcripts contain no quota fields at all, so
Polyhelm reports what you *spent* rather than inventing a denominator. Harnesses
that expose nothing say so, instead of showing a zero that looks like data.

Cache reads are excluded from token headlines — they run ~30x the billable
figure and would swamp it.

## Agent logos

Each session and usage row carries its harness's mark, resolved at runtime in
priority order:

1. `~/.polyhelm/logos/<brand>.{svg,pdf,png,jpg}` — per-machine override
2. `Logos/` bundled into the app at build time — **empty by default**
3. The vendor's own asset inside their installed app — Claude's 248x248 burst
   from `Claude.app`, OpenAI's `blossom-white.svg` from the ChatGPT extension
4. The installed app's icon via `NSWorkspace`
5. Original geometric marks drawn in code

Check what resolved, and from where:

```bash
.build/arm64-apple-macosx/debug/Polyhelm --logos
```

### If you distribute this

Levels 3-5 need nothing from you and redistribute nothing — each user's copy
reads their own machine. A recipient without Claude installed sees the drawn
fallback, which is original artwork with no strings.

Level 2 is different. Copying a vendor's logo out of their app and into a binary
you hand to other people is redistribution of copyrighted artwork, separate from
the trademark question. Vendors publish brand assets with terms that cover this
properly — `Logos/README.md` lists where to get them. That folder ships empty
because filling it is a licensing decision, not a build step.


## Interaction

Everything in the expanded panel is clickable on the **first** click, including
when Polyhelm is not the active app.

- **Sessions / Usage tabs** across the top
- **Usage tab** has a mark-per-harness switcher; pick one for its full breakdown
- **A session blocked on a question** gets an inline answer box with `yes` / `no`
  / `continue` one-tap replies and a free-text field
- **Approvals** get Allow / Deny plus deny-with-a-note
- **Compose bar** targets whichever session is selected; click a row to retarget

### The bug that made none of this work

Polyhelm is an `.accessory` app, so it is almost never frontmost. macOS spends
the first click on an inactive app's window activating it rather than delivering
it to a control — and since the panel never took key focus, *every* click was a
first click. Buttons, tabs and text fields received nothing.

Three fixes, all required:

- `acceptsFirstMouse` on the hosting view, so the click that reaches the window
  also reaches the control under it
- `mouseDown` takes keyboard focus on press rather than on a completed tap, so
  text fields are typable immediately
- a container-level `onTapGesture` was competing with child buttons for the same
  clicks; focus is handled in AppKit now, so it is gone

Usage also moved out of a `.popover`. Popovers presented from a borderless,
non-key panel are unreliable — that is why the harness switcher appeared dead.
It is a real tab in the view hierarchy now, which needs no window presentation.

## Opening and closing

Five ways to close it, because one is never enough:

- move the pointer away (420 ms grace, so brushing past doesn't slam it shut)
- click anywhere outside the panel
- **⎋**
- the chevron in the header
- **⌥⌘Space** again

It refuses to auto-close in exactly two cases: an approval is waiting on you, or
you have an unsent draft in the compose bar. Both still close on an explicit
action.

## Keyboard

- **⌥⌘Space** — summon the island and focus it (system-wide), or close it
- **⏎ / ⎋** — allow / deny the top approval card
- **⎋** — collapse, when nothing is waiting on a decision

The ⏎/⎋ hints only render when the panel actually holds keyboard focus, because
a shortcut hint for a key that does nothing is worse than no hint. Get focus by
clicking the panel, hitting ⌥⌘Space, or enabling **Focus notch on approval**.

## Terminal jump

Clicking a session focuses where it's running. Matching is anchored on the
controlling **tty** where possible — it survives session restores and is the one
identifier every emulator agrees on:

- **iTerm2** — exact window + tab + split, by `tty`, falling back to `ITERM_SESSION_ID`
- **Terminal.app** — exact tab, by `tty`
- **WezTerm** — exact pane via `wezterm cli activate-pane`
- **kitty** — exact window via `kitty @ focus-window`
- **tmux** — selects the pane first, then fronts the host emulator
- **Ghostty, Warp, Alacritty, Hyper, VS Code, Zed** — app focus

Sessions with no controlling terminal — the **Claude Code desktop app**, and
**Conductor** workspaces — can't be *typed* into, but they can still be *jumped*
to: the row's arrow brings the owning app (Claude, Conductor) to the front. Only
a session with genuinely nowhere to go falls back to the inert desktop glyph.

First use will ask for Automation permission (iTerm2 / Terminal.app need
AppleScript).

## Performance

Idle **and while sessions are actively running: 0% CPU**, ~95-150 MB. The window is a fixed transparent canvas that never
resizes — only the shape inside it morphs — and `@Published` state is only
touched when something actually changed. (An earlier build reassigned the session
array on a 1-second timer, which forced a full SwiftUI redraw every second and
cost ~7% CPU forever.)

Clicks outside the island fall through via `hitTest`, so the transparent canvas
doesn't swallow input meant for whatever is behind it.

Three separate always-on costs were found by measuring rather than guessing, and
each is worth knowing about if you extend this:

- **`AVAudioEngine` left running** keeps its render and messenger threads alive
  and burns ~7% CPU rendering silence. It is now started on the first sound and
  torn down after 5 idle seconds.
- **A SwiftUI `repeatForever` animation** ticks the process's render loop every
  frame — the single pulsing status dot cost ~6-8% CPU on its own. It is now a
  `CABasicAnimation` handed to the render server, which costs this process
  nothing per frame. (Removing its `.shadow()` first helped, but was not the
  real cause.)
- **Unconditional `@Published` reassignment on a timer** forces a full redraw
  every tick even when nothing changed.

Idle now measures 0.1-0.5%, with a brief spike once a minute when the usage scan
runs.

One trap worth naming: moving the pulse to Core Animation fixed the CPU but
broke the layout. An `NSViewRepresentable` with no explicit SwiftUI `.frame`
expands to fill everything offered — it swallowed each session row's width and
pushed the text to the right edge. Any representable in this codebase needs a
frame and `.fixedSize()`.

## Fitting the notch, on any display

Every dimension is derived from the host screen. Check yours:

```bash
.build/arm64-apple-macosx/debug/Polyhelm --geometry
```

| | Derived from |
|---|---|
| notch width | `frame.width - auxTopLeft - auxTopRight`, sanity-bounded to 100-400pt |
| notch height | `safeAreaInsets.top` — never assumed to be 32 |
| wing width | `min(76, max(52, screenWidth x 0.045))` |
| expanded panel | `min(620, max(380, screenWidth x 0.34))` |
| canvas | panel + 60 wide, `62%` of screen height, capped |
| vertical anchor | screen top on a notched Mac, **below the menu bar** everywhere else |

That last row was a bug: the panel anchored to `frame.maxY` on every screen, so
on an external display it sat on top of the menu bar.

The physical notch is opaque hardware with no pixels, so anything visible has to
sit in the wings beside it. "Fitting" therefore means: match the height exactly,
be exactly `notchWidth x notchHeight` (and so invisible) when nothing is running,
and never overhang more than the content needs. Verified from 800x600 up to a Pro
Display XDR; `--render-preview --collapsed` warns on stderr if a wing overflows.


## Multi-display

The island pins to the built-in notched display and stays there, rather than
following keyboard focus between screens. On a Mac with no notch it renders the
same shape as a floating bar under the menu bar.

## Seeing the UI without running it

The app is an `LSUIElement` overlay, so ordinary screenshot tooling can't capture
it. That made every layout change a guess. It can now render itself offscreen:

```bash
swift build
.build/arm64-apple-macosx/debug/Polyhelm --render-preview /tmp/expanded.png
.build/arm64-apple-macosx/debug/Polyhelm --render-preview /tmp/collapsed.png --collapsed
```

It hosts the real view tree in a real `NSHostingView` with mock sessions, so
`NSViewRepresentable` sizing bugs reproduce exactly as they do on screen — which
is how the row-layout bug below was found. Materials render as clear in an
offscreen cache, so the preview paints an opaque backdrop; that is the one way
the capture differs from the live panel.

## Debugging

```bash
curl -s localhost:8787/health          # is it running
curl -s localhost:8787/sessions | jq   # what does it think is happening
curl -s localhost:8787/usage | jq      # usage per harness
```

If sessions never appear: check `~/.claude/settings.json` actually has the hook
entries, confirm `jq` is on `PATH` inside your shell, and make sure only one copy
of the app is running (it holds port 8787 exclusively).

## Layout

```
Sources/Polyhelm/
  main.swift          NSApplication setup, menu bar item
  HTTPServer.swift    loopback HTTP/1.1, supports deferred responses
  EventRouter.swift   hook payload → session state
  CodexSessionWatcher.swift     polls ~/.codex/sessions rollouts
  ConductorSessionWatcher.swift reads Conductor's SQLite state, read-only
  SessionStore.swift  observable state, parked permission continuations
  NotchWindow.swift   notch geometry, non-activating panel
  NotchView.swift     collapsed wings + expanded panel
  SessionRow.swift    one agent
  PermissionCard.swift  allow/deny card
  Chiptune.swift      synthesized 8-bit event sounds
  UsageTracker.swift  aggregates every provider
  UsageProviders.swift  per-harness readers (Codex quota, opaque probes)
  UsagePanel.swift    usage chip + per-harness popover
  AgentBrand.swift    brands, tints, marks, custom-logo loading
  PromptBar.swift     compose bar
  Settings.swift      persisted preferences
  HotKey.swift        ⌥⌘Space via Carbon RegisterEventHotKey
  TerminalJump.swift  per-emulator focus
  HookInstaller.swift settings.json wiring
```

The deferred-response design in `HTTPServer` is what makes approvals work: the
connection from the hook stays open while the request sits in `SessionStore`, and
is only written once you decide.

`Chiptune` renders each cue to a PCM buffer off the audio thread and replays it
through an `AVAudioPlayerNode` — nothing locks or allocates inside the render
callback, which is the rule for real-time audio.
