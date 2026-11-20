# claude-pair

Pair-program with Claude inside Emacs. Claude runs in a background daemon,
`claude-paird`, written in Go, which drives your installed Claude Code (`claude`)
in its headless stream-json mode. Emacs is the client: a chat buffer, Claude's
edits reviewed in your real buffers, and windows Claude opens for you within
limits you set.

**Status:** phase 1, milestone 4. You can chat with Claude about a project,
watch its tool calls, stop an answer, allow or deny each command, and review
every edit Claude proposes in the file's own buffer before it happens. See
[PHASE-1.org](PHASE-1.org).

## Requirements

- Emacs 29.1 or later (developed on 30.1)
- Go 1.24 or later, to build the daemon from source
- Claude Code 2.1.0 or later (`claude` on your PATH)

## Try it from a checkout

```sh
make daemon   # build daemon/bin/claude-paird
make check    # go vet, gofmt, byte-compile, checkdoc, Go tests (race detector), ERT tests
              # (no test calls the model: they use daemon/bin/fakeclaude)
```

Then start a clean Emacs with the package on the load path:

```sh
emacs -Q -L ~/personal-projects/claude-pair/lisp --eval "(require 'claude-pair)"
```

or add this to your init file:

```elisp
(add-to-list 'load-path "~/personal-projects/claude-pair/lisp")
(require 'claude-pair)
```

Emacs finds the daemon on your `exec-path` as `claude-paird`, or else uses the
one `make daemon` built. Set `claude-pair-daemon-command` to use another.

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
file's buffer as a proposal, with a line above it: the text to go struck
through, and the new text below it as real lines you can scroll through,
move around in and read, highlighted by the buffer's mode. Both are
read-only until you decide. The new text is for display only: it is not an
undo step, it does not mark the buffer modified, and saving (`C-x C-s`)
writes only your text, with the proposal taken out while your save hooks
and formatters run:

| Key | What it does |
|---|---|
| `C-c C-a` | Apply the edit, with point on the proposal (one undo step) |
| `C-c C-k` | Reject it; you can tell Claude why |

The chat shows the same proposal as a block, where `y` applies it, `n`
rejects it, `d` rejects it with a note and `RET` shows it. `M-x
claude-pair-review-apply` and `M-x claude-pair-review-reject` work from
anywhere.

An applied edit is saved when the buffer had no unsaved changes of yours
(`claude-pair-review-autosave`). Otherwise it stays unsaved, and Claude is
told that commands reading the file from disk still see the old version.
Edits are checked against the live buffer, unsaved changes included, with
the same rules as Claude Code's own Edit tool. Files are opened with unsafe
local variables ignored, and only files inside the project can be edited.
If the file is reloaded from disk while a proposal is shown (`revert-buffer`,
auto-revert), the proposal is dropped and Claude is told to read the file
again.

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
with: your Claude Code login, or `ANTHROPIC_API_KEY`, Amazon Bedrock or
Google Vertex AI from the environment. The daemon inherits the environment of
the Emacs that started it, so restart the daemon
(`M-x claude-pair-stop-daemon`) after changing those variables.
`claude-pair-claude-command` picks a specific `claude`, and `claude-pair-model`
a model for new sessions.

## The daemon

The daemon listens on `$XDG_RUNTIME_DIR/claude-pair/daemon.sock` and logs to
`daemon.log` in the same directory. It stops by itself after 10 minutes with
no Emacs connected (`claude-pair-daemon-idle-timeout`).

## Layout

| Path | Contents |
|---|---|
| `lisp/` | The Emacs package |
| `daemon/` | `claude-paird`, in Go (`cmd/claude-paird`, `internal/…`) |
| `protocol/PROTOCOL.md` | The contract between the two |
| `test/` | ERT tests, shared helpers and the checkdoc runner |
| `daemon/internal/testutil/fakeclaude` | A stand-in for Claude Code that the tests drive; it never calls a model |
| `PHASE-1.org` | The phase 1 checklist, with automatic and visual tests |

## License

GPL-3.0-or-later.
