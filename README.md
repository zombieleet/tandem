# claude-pair

Pair-program with Claude inside Emacs. Claude runs in a background daemon,
`claude-paird`, written in Go, which drives your installed Claude Code (`claude`)
in its headless stream-json mode. Emacs is the client: a chat buffer, Claude's
edits reviewed in your real buffers, and windows Claude opens for you within
limits you set.

**Status:** phase 1, milestone 1. Emacs can start the daemon, connect to it
and stop it. Chat, permissions, edits and window layout come next; see
[PHASE-1.org](PHASE-1.org).

## Requirements

- Emacs 29.1 or later (developed on 30.1)
- Go 1.24 or later, to build the daemon from source
- Claude Code (`claude` on your PATH), logged in, from milestone 2 on

## Try it from a checkout

```sh
make daemon   # build daemon/bin/claude-paird
make check    # go vet, gofmt, byte-compile, checkdoc, Go tests (race detector), ERT tests
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
| `M-x claude-pair-connect` | Connect, starting the daemon if it isn't running |
| `M-x claude-pair-daemon-status` | Show the daemon's version, pid, uptime and clients |
| `M-x claude-pair-events-buffer` | Show every message exchanged with the daemon |
| `M-x claude-pair-disconnect` | Close the connection; the daemon keeps running |
| `M-x claude-pair-stop-daemon` | Stop the daemon |

The daemon listens on `$XDG_RUNTIME_DIR/claude-pair/daemon.sock` and logs to
`daemon.log` in the same directory. It stops by itself after 10 minutes with
no Emacs connected (`claude-pair-daemon-idle-timeout`).

## Layout

| Path | Contents |
|---|---|
| `lisp/` | The Emacs package |
| `daemon/` | `claude-paird`, in Go (`cmd/claude-paird`, `internal/…`) |
| `protocol/PROTOCOL.md` | The contract between the two |
| `test/` | ERT tests and the checkdoc runner |
| `PHASE-1.org` | The phase 1 checklist, with automatic and visual tests |

## License

GPL-3.0-or-later.
