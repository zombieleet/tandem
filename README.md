# claude-pair

Pair-program with Claude inside Emacs. Claude runs in a background daemon,
`claude-paird`, written in Go, which drives your installed Claude Code (`claude`)
in its headless stream-json mode. Emacs is the client: a chat buffer, Claude's
edits reviewed in your real buffers, and windows Claude opens for you within
limits you set.

**Status:** phase 1, milestone 6 (wrap-up). You can chat with Claude about a project,
watch its tool calls, stop an answer, allow or deny each command, review
every edit Claude proposes in the file's own buffer before it happens, and
let Claude show you files in up to 5 windows without ever taking your cursor.
See [PHASE-1.org](PHASE-1.org).

## Requirements

- Emacs 29.1 or later
- Claude Code 2.1.0 or later (`claude` on your `PATH`), logged in or set up
  with an API key, Amazon Bedrock or Google Vertex AI
- Linux or macOS
- Go 1.24 or later, only to build the daemon yourself

## Install

claude-pair has two parts: the Emacs package in `lisp/` and the daemon,
`claude-paird`.

**The daemon.** Build it from a checkout:

```sh
git clone https://github.com/victory/claude-pair ~/src/claude-pair
cd ~/src/claude-pair && make daemon      # daemon/bin/claude-paird
```

The package finds a daemon built there by itself. Or download a prebuilt one
for Linux or macOS (amd64 or arm64) from the releases page, check it, and put
it on your `PATH` as `claude-paird`:

```sh
sha256sum -c --ignore-missing SHA256SUMS        # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
install -m 755 claude-paird-0.1.0-linux-amd64 ~/.local/bin/claude-paird
```

On macOS, a downloaded binary is quarantined until you run `xattr -d
com.apple.quarantine ~/.local/bin/claude-paird`. If Emacs does not see your
shell's `PATH` (common for the macOS app), set `claude-pair-daemon-command`
to `'("/full/path/to/claude-paird")`, and `claude-pair-claude-command` the
same way if `claude` is not found.

**The package**, with a suggested key binding (`C-c` and a letter are yours
to bind; pick any free one):

```elisp
(use-package claude-pair
  :load-path "~/src/claude-pair/lisp"
  :commands claude-pair
  :bind ("C-c C" . claude-pair))
```

Without `use-package`:

```elisp
(add-to-list 'load-path "~/src/claude-pair/lisp")
(autoload 'claude-pair "claude-pair" nil t)
(keymap-global-set "C-c C" #'claude-pair)
```

To try it without touching your configuration:

```sh
emacs -Q -L ~/src/claude-pair/lisp --eval "(require 'claude-pair)"
```

## Use

`M-x claude-pair` in any file of a project opens the chat in a tab named
"Claude". Type after the `❯` prompt and send with `C-c C-c`.

| Command | What it does |
|---|---|
| `M-x claude-pair` | Chat with Claude about the current project (`C-u` starts a new session) |
| `M-x claude-pair-connect` | Connect, starting the daemon if it isn't running |
| `M-x claude-pair-daemon-status` | Show the daemon's version, pid, uptime and clients |
| `M-x claude-pair-events-buffer` | Show every message exchanged with the daemon |
| `M-x claude-pair-disconnect` | Close the connection; the daemon keeps running |
| `M-x claude-pair-stop-daemon` | Stop the daemon |

In the chat buffer, type after the `❯` prompt:

| Key | What it does |
|---|---|
| `C-c C-c` | Send your message |
| `C-c C-k` | Stop Claude's answer; your next message continues the conversation |
| `C-c C-p` | Answer Claude's oldest permission question from a menu |
| `M-p` / `M-n` | Step through messages you sent earlier |

The header line shows the model, what Claude is doing, and the session's cost
so far. Each tool call is one line: `▸` while it runs, `✓` or `✗` when done.

## Reviewing edits

Claude never writes your files behind your back. Each edit appears in the
file's buffer as a proposal, split into hunks: the blocks of lines that
change, each with a line above it ("hunk 2 of 3"). The lines between hunks
are left alone, and you can keep editing them. In a hunk the text to go is
struck through, and the new text sits below it as real lines you can scroll
through, move around in and read, highlighted by the buffer's mode. Both are
read-only until you decide. The new text is for display only: it is not an
undo step, it does not mark the buffer modified, and saving (`C-x C-s`)
writes only your text, with the proposal taken out while your save hooks
and formatters run.

With point on a hunk:

| Key | What it does |
|---|---|
| `C-c C-a` | Apply the hunk (one undo step) and move to the next |
| `C-c C-k` | Reject it; you can tell Claude why |
| `C-c '` | Ask Claude about it first (`@claude …`) |
| `C-u C-c C-a`, `C-u C-c C-k` | The same for every hunk of the edit |
| `n`, `p` | On the hunk's own text: the next or previous hunk |

When point rests in a hunk for a moment (`claude-pair-popup-delay`, 0.3 s),
or the mouse hovers over one, a small popup opens below it: "Claude · hunk 2
of 3 · file" with ✓ Approve and ✗ Reject… buttons. In a graphical Emacs it
is a child frame that never takes focus, so you keep typing where you were;
in a terminal the hunk's banner line lights up and its "apply" and "reject"
parts are the buttons. `M-RET` opens it at once; it closes when point
leaves the hunk. `claude-pair-popup-style` picks `child-frame`, `inline` or
nil (never).

Asking (`C-c '`, or "@ Ask Claude…" in the popup) sends the edit back to
Claude with your question. Hunks you already decided keep their decision;
the rest are not applied, and Claude answers and proposes them again,
revised if your question calls for it. The answer streams into the chat
and into a note where the hunk was (`┃ @claude …`), which `[×]` or `M-x
claude-pair-review-dismiss-note` removes; the note shows the first
`claude-pair-review-note-lines` lines (6).

Claude hears what happened to every hunk, with your notes, once the last
one is decided. The chat shows the edit as a block with its number of
hunks, where `y` applies all of them, `n` rejects all, `d` rejects all with
a note and `RET` shows the first hunk. Changes at most
`claude-pair-review-merge-gap` unchanged lines apart (2) make one hunk.

An applied hunk is saved when the buffer had no unsaved changes of yours
(`claude-pair-review-autosave`). Otherwise it stays unsaved, and Claude is
told that commands reading the file from disk still see the old version.
Edits are checked against the live buffer, unsaved changes included, with
the same rules as Claude Code's own Edit tool. Files are opened with unsafe
local variables ignored, and only files inside the project can be edited.
If the file is reloaded from disk while a proposal is shown (`revert-buffer`,
auto-revert), the proposal is dropped and Claude is told to read the file
again.

## Claude's lines keep their colour

Text Claude wrote, through an edit you applied, keeps a light tint
(`claude-pair-author-color`, Claude's orange, blended at
`claude-pair-author-tint`, 10%, into your theme's background, recomputed
when you change themes) and, in a graphical Emacs, a mark in the left
fringe, so colour is never the only signal.

Any change of yours takes the colour off every line it touches: typing on
the line, or pasting Claude's text elsewhere (pasted text is yours).
Opening a new line after one of Claude's lines, or deleting whole lines
around it, does not touch it. Undo and redo bring the colour back or take
it away with the text. With `claude-pair-attribution-ignore-whitespace`
(on), a line whose only change is whitespace keeps its colour, so
reindenting and formatters do not wipe it.

The colours outlive the buffer and Emacs itself. Each save writes, under
`claude-pair-attribution-directory` (`~/.cache/claude-pair/attribution`,
private to you), a fingerprint of every line of the file and which lines
are Claude's; opening the file again finds those lines where they are now,
even after lines were added above them, and a line changed meanwhile loses
its colour. `claude-pair-attribution-persist` turns this off.

`M-x claude-pair-blame` says who wrote the line at point: "Claude (model)
wrote this line, in chat 1a2b3c4d, turn 3, 21 Nov 14:02, answering: "add
docstrings"". With `C-u`, it lists every run of Claude's lines in the
buffer, each a link to its lines.

## Claude's windows

`M-x claude-pair` opens the chat in a tab of its own, named "Claude"
(`claude-pair-layout-tab`; nil keeps the current tab). Claude works only in
the frame and tab where its chat is shown, so your other tabs keep their
layout. When you look elsewhere, Claude is told that nothing can be shown.

Claude shows you files with its `open_file` tool, at the line it is talking
about. These rules hold whatever Claude asks for:

- **At most 5 windows** (`claude-pair-max-windows`), the chat included.
  Claude uses a window that already shows the file, else splits the largest
  window, else reuses the window it used least recently.
- **At least 2** (`claude-pair-min-windows`). Windows Claude split off are
  its own; it can close only those, never yours or the chat.
- **Focus guard.** Claude never selects a window, never changes or scrolls
  the window you are in, and leaves alone any window you used in the last 3
  seconds (`claude-pair-focus-guard-seconds`).
- `C-x 1` keeps the chat window.

Edit proposals open by the same rules. When the chat is not shown, an
edit proposal or permission question comes to you, since Claude is waiting
for you, except when you are in another tab than Claude's: then your tab is
left alone and the echo area tells you to switch (`C-x t o`).

## Permission questions

When Claude wants to run a command, fetch a page or use another tool that
needs your approval, the question appears in the chat:

```
  ⏸ Claude wants to run:
      make test
    y allow once   a always allow Bash(make test)   n deny   d deny with a reason
```

With point on the question, press the key. `a` adds the rule shown, which
Claude Code saves in the project's `.claude/settings.local.json`, the same
file its own "don't ask again" uses. `d` asks what to tell Claude instead.
If the chat is hidden it pops up, and the echo area says a question is
waiting. Nothing is asked in the minibuffer behind your back, so a stray
keystroke elsewhere cannot approve a command. `M-x claude-pair-answer-permission`
answers from any buffer; bind it to a key if you like.

## Credentials

The daemon runs your installed `claude`, which uses whatever it is set up
with: your Claude Code login, or an API key, Amazon Bedrock or Google Vertex
AI from the environment.

Each new chat takes the credential variables (`claude-pair-environment-variables`:
`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, the Bedrock and Vertex switches,
the proxies and a few more) from Emacs as they are at that moment. To switch,
say to an API key for a while:

1. `M-x setenv RET ANTHROPIC_API_KEY RET` and paste the key. It stays in
   that Emacs only; nothing is written to disk.
2. Start a new chat: `C-u M-x claude-pair`.

`C-u M-x setenv RET ANTHROPIC_API_KEY RET` removes it again; the next new
chat uses your login. Chats already open keep what they started with.
Values never appear in the daemon's log.

## The daemon

The daemon listens on `$XDG_RUNTIME_DIR/claude-pair/daemon.sock` (on macOS,
`$TMPDIR/claude-pair-<uid>/daemon.sock`) and logs to `daemon.log` in the same
directory, which must be private to you. It outlives Emacs and stops by
itself after 10 minutes with no Emacs connected (reopening an earlier chat
comes in phase 2).

## Configuration

`M-x customize-group RET claude-pair` lists everything. The ones you are most
likely to change:

| Option | Default | What it does |
|---|---|---|
| `claude-pair-layout-tab` | `"Claude"` | Tab the chat opens in; nil keeps the current tab |
| `claude-pair-max-windows` | 5 | Most windows Claude's frame may have when Claude adds one |
| `claude-pair-min-windows` | 2 | Fewest windows Claude leaves when it closes one |
| `claude-pair-focus-guard-seconds` | 3 | How long after you use a window Claude leaves it alone |
| `claude-pair-review-autosave` | t | Save a buffer after applying Claude's edit, if it had no unsaved changes of yours |
| `claude-pair-model` | nil | Model for new chats, such as `"opus"`; nil for Claude Code's default |
| `claude-pair-environment-variables` | credentials, provider, proxies | Variables each new chat takes from Emacs |
| `claude-pair-claude-command` | nil | Path of `claude`; nil looks on `exec-path` |
| `claude-pair-daemon-command` | nil | Command that runs the daemon; nil looks on `exec-path`, then in the checkout |
| `claude-pair-daemon-idle-timeout` | 600 | Seconds the daemon waits with no Emacs before it stops; 0 never |
| `claude-pair-chat-window-width` | 0.38 | Width of the chat window, as a fraction of the frame or in columns |
| `claude-pair-socket-path` | nil | The daemon's socket; nil for the default above |

## Troubleshooting

| You see | Do this |
|---|---|
| "…speaks protocol X, but the running claude-paird speaks Y" | Answer `y` to restart it, or `M-x claude-pair-stop-daemon`. It happens after upgrading. |
| "Cannot find claude-paird" | `make daemon` in the checkout, or set `claude-pair-daemon-command`. |
| "…has mode 775, so other users can reach the socket" | `chmod 700` that directory, or set `claude-pair-socket-path` to a private one. |
| "claude … is too old" or not found | Update Claude Code, or set `claude-pair-claude-command`. |
| A changed key or login is not used | Start a new chat with `C-u M-x claude-pair`. |
| Anything else | `M-x claude-pair-events-buffer` shows every message; `daemon.log` sits next to the socket. |

## Development

```sh
make check    # go vet, gofmt, versions, byte-compile, checkdoc, Go tests (race detector), ERT tests
              # (no test calls the model: they use daemon/bin/fakeclaude)
make dist     # static daemons for Linux and macOS, amd64 and arm64, with SHA256SUMS, in dist/
make help     # every target
```

A release is a tag `vX.Y.Z` matching both `;; Version:` in `lisp/claude-pair.el`
and `daemon/internal/version`; pushing it builds the daemons and publishes them.

## Layout

| Path | Contents |
|---|---|
| `lisp/` | The Emacs package |
| `daemon/` | `claude-paird`, in Go (`cmd/claude-paird`, `internal/…`) |
| `protocol/PROTOCOL.md` | The contract between the two |
| `test/` | ERT tests, shared helpers and the checkdoc runner |
| `daemon/internal/testutil/fakeclaude` | A stand-in for Claude Code that the tests drive; it never calls a model |
| `PHASE-1.org` | The phase 1 checklist, with automatic and visual tests |
| `.github/workflows/` | CI (`make check` on Linux and macOS, Emacs 29.1 and 30.1) and releases |

## License

GPL-3.0-or-later.
