# Security

tandem is a tool for one person on their own machine. This document
says what it trusts, what it treats as untrusted, how each way in is
guarded, and what the review of November 2026 found and fixed.

## What is trusted, and what is not

**Trusted:** you, your Emacs, your user account, and Claude Code (`claude`)
as you installed it. Anyone who runs programs as your user can already do
everything tandem can, so tandem does not defend against them.

**Not trusted:**

- **Other users of the machine.** They must not reach the daemon, your
  credentials, or what you send to Claude.
- **Text Claude writes**, in the chat, in plans and in answers put into
  your Org files. It may repeat what a file in the project or a web page
  told it to say (a prompt injection), so it is displayed, never run.
- **Files in a project.** Claude may read and propose to change them;
  tandem never runs code from them by itself.

## Ways in, and how they are guarded

| Way in | Guard |
|---|---|
| The daemon's Unix socket | In a directory that must be yours and mode `0700` (the daemon refuses a less private one, and never `chmod`s it); the socket is `0600` |
| The daemon's TCP port (Windows, or `--tcp`) | Listens on `127.0.0.1` only; every client must send a 64-hex-digit token from the endpoint file (`0600`, in your own `%LOCALAPPDATA%`), compared in constant time; `shutdown` before the handshake needs it too |
| Messages on the connection | Bodies of at most 64 MB, headers of at most 4 KB |
| Credentials | Passed to `claude` in its environment, never on a command line, never logged (a test checks the log) |
| Paths in Claude's tool calls | Made absolute and refused outside the project, symbolic links resolved; on Windows a path such as `\etc\hosts` is read on the project's drive, not inside the project |
| Session IDs from Emacs | Must be UUIDs before they name a transcript file, so no path can be built from one |
| Edits | Every edit Claude proposes waits for your review in the buffer, unless you chose the auto-accept review style |
| Commands Claude runs | Claude Code asks, and tandem puts the question to you; "always allow" saves the narrowest rule (the exact command, or a web domain) |
| Files Claude names | Opened with only safe file-local variables, never `eval:` ones |
| Text Claude writes | Coloured by major modes only; never turned into Org settings or clickable `elisp:` / `shell:` links |
| Commit messages Claude drafts | The staged diff goes to `claude` on its standard input, never its command line |
| What this machine remembers of Claude's lines | In `~/.cache/tandem/attribution`, directory `0700`, files `0600` |
| Suggestions as you type | Only when you turn the mode on; only the file's name and the text around the cursor go, to a claude with no tools, no settings and no MCP servers, run in an empty directory of the daemon's; the text comes back as grey text, inserted only with `TAB` |
| Git notes others may read | Line fingerprints, model, session ID and time: no code and no paths of your machine |

## Fixed in the review (November 2026)

1. **A code block's language could call any `-mode` function.** The chat
   coloured ```` ```NAME ```` blocks with `NAME-mode`, whatever it was:
   ```` ```server ```` would have toggled `server-mode`, and a name of
   another global minor mode would have toggled it. Now only real major
   modes are called (known to `auto-mode-alist`, or derived modes), never a
   minor mode, and only names made of letters, digits, `+`, `#` and `-`.
2. **The staged diff was on a command line.** Drafting a commit message
   passed the request, with the whole diff, as an argument to `claude`, so
   other users could read it with `ps`, secrets in the diff included. It
   now goes on standard input.
3. **Answers put into Org could act on the Org file.** A line such as
   `#+INCLUDE:`, `#+SETUPFILE:` or `#+BIND:` from Claude became a keyword of
   your Org file. Such lines are now shown as fixed-width text (`: #+…`).
4. **Markdown links became any kind of Org link.** `[x](elisp:(…))` became
   a clickable `elisp:` link, which runs code if you turned off Org's
   confirmation. Only `http`, `https`, `file` and `mailto` links are
   turned into Org links now.

Each fix has a test (`test/tandem-security-tests.el`).

## Accepted, and why

- **A program running as you can use the daemon fully,** including
  starting any program as `claude`: it could do that without the daemon.
- **Opening a file Claude names runs its major mode and your hooks for
  it,** as opening it yourself would (a language server may start).
- **The read-only Emacs tools need no permission:** diagnostics, xref,
  imenu, and your selection (its text, when a region is active) go to
  Claude when it asks, as reading a file in the project would.
- **Suggestions send code as you type:** with the mode on, the code around
  the cursor goes to Claude at each pause after typing, also in a file
  you have not asked Claude about (a secret in it included). Turn the mode
  on only where you want that.
- **The auto-accept review style** applies Claude's edits without asking:
  you choose it.
- **Claude Code's own files** (transcripts and approved plans under
  `~/.claude/`) are kept by Claude Code, not tandem.

## Dependencies

The daemon depends on the MCP Go SDK and a few `golang.org/x` modules
(see `daemon/go.mod`). Check them for known vulnerabilities with:

```sh
cd daemon && go run golang.org/x/vuln/cmd/govulncheck@latest ./...
```

In November 2026 it found nothing in tandem's code or its modules,
but five bugs in the standard library of Go 1.26.1, the Go it was built
with: GO-2026-6859, GO-2026-6617, GO-2026-6613 and GO-2026-6612 (crashes
and desynchronisation in Go's HTTP server) and GO-2026-6809 (compromised
intermediate certificates). tandemd runs no HTTP server and makes no
TLS connections, so none of them can be triggered in it; govulncheck
reaches them through HTTP code in the MCP library that tandemd never
uses. Go 1.27.3 fixes four of them; GO-2026-6859 needs 1.27.4. Release
binaries carry the standard library all the same, so they are built with
a Go that has every fix: `make dist` refuses one older than 1.27.4, and
the release workflow uses the newest Go. The scan also named
GO-2026-5024 in `golang.org/x/sys/windows` (Windows only, in a function
tandemd never calls); the module is updated to a version with the
fix (0.48.0), so building needs Go 1.26 or later.

## Reporting a problem

Until the project has a public repository, tell the author directly.
Once it has one, use its private security advisories, not a public issue.
