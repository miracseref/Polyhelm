# Bundled logo artwork

Files here are copied into `Polyhelm.app/Contents/Resources/Logos/` at build
time and used on machines that don't have the corresponding harness installed.
**This folder ships empty on purpose.**

Name files after the brand id: `claudeCode`, `codex`, `gemini`, `cursor`,
`opencode` — `.svg`, `.pdf` or `.png`. Square artwork, 64px or larger.

## Before you put anything here

Polyhelm resolves logos at runtime from the vendor's own installed app, which
is fine because nothing is redistributed. Putting a file *here* is different:
it gets copied into the app you hand to other people.

Company logos are copyrighted artwork as well as trademarks. Extracting them
from inside `Claude.app` or a VS Code extension and shipping them in your own
binary is redistribution, whatever the intent. Most vendors publish brand assets
with explicit terms covering exactly this — get them from the source:

| Harness | Where to get artwork |
|---|---|
| Claude Code | anthropic.com brand / press resources |
| Codex | openai.com brand guidelines |
| Gemini | Google brand permissions |
| Cursor | cursor.com press kit |

Typical conditions: use the mark only to refer to that product, don't modify it,
don't imply endorsement. Those are easy to satisfy here — the mark sits next to
a session from that tool, which is textbook nominative use.

If you'd rather not deal with it, leave this folder empty. The app falls back to
its own geometric marks, which are original and ship with no strings.
