# claude-pair

Pair-program with Claude inside Emacs. Claude runs in a background daemon,
`claude-paird`, written in Go, which drives your installed Claude Code (`claude`)
in its headless stream-json mode. Emacs is the client: a chat buffer, Claude's
edits reviewed hunk by hunk in your real buffers, the lines Claude wrote kept
in colour, windows Claude opens for you within limits you set, and what
Emacs knows (diagnostics, definitions, your selection) for Claude to ask.

**Status:** phase 4 (ecosystem) is done. You can chat with Claude about a
project, watch its tool calls, stop an answer, and allow or deny each
command. You review every edit Claude proposes in the file's own buffer,
hunk by hunk, from keys or a small popup next to the hunk, and ask Claude
about a hunk, or any code, before deciding. Claude's lines keep a colour
until someone else edits them, and Claude shows you files in up to 5
windows without ever taking your cursor. Point Claude at files, buffers
and regions with `@`; Claude asks Emacs for diagnostics, definitions,
outlines and your selection itself. Reopen earlier chats, run slash
commands, and go back to before any message, files included. Code in the
chat is in colour. Windows support is built and tested under Wine. With
Magit, stage only Claude's hunks and have Claude draft the commit
message; Claude's lines travel with the repository in git notes. Plan
in an Org buffer you edit, send Org subtrees as tasks, ask from Embark,
and run several Claudes at once, one per git worktree, from a dashboard.
See [PHASE-1.org](PHASE-1.org), [PHASE-2.org](PHASE-2.org),
[PHASE-3.org](PHASE-3.org) and [PHASE-4.org](PHASE-4.org).

## Requirements

- Emacs 29.1 or later
- Claude Code 2.1.0 or later (`claude` on your `PATH`), logged in or set up
  with an API key, Amazon Bedrock or Google Vertex AI
- Linux or macOS; Windows support is built and tested under Wine, not yet
  on a real Windows (see [Windows](#windows))
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
for Linux, macOS or Windows (amd64 or arm64) from the releases page, check it,
and put it on your `PATH` as `claude-paird` (`claude-paird.exe` on Windows):

```sh
sha256sum -c --ignore-missing SHA256SUMS        # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
install -m 755 claude-paird-0.4.0-linux-amd64 ~/.local/bin/claude-paird
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
  :demand t
  :bind ("C-c C" . claude-pair))
```

Without `use-package`:

```elisp
(add-to-list 'load-path "~/src/claude-pair/lisp")
(require 'claude-pair)
(keymap-global-set "C-c C" #'claude-pair)
```

Load it at startup, as here, rather than on first use: it takes about
60 ms and starts no daemon, and from then on Claude's lines get their
colour back in files you open, and commits get their git notes, even
before you open a chat.

To try it without touching your configuration:

```sh
emacs -Q -L ~/src/claude-pair/lisp --eval "(require 'claude-pair)"
```

## Use

`M-x claude-pair` in any file of a project opens the chat in a tab named
"Claude". Type after the `❯` prompt and send with `C-c C-c`.

| Command | What it does |
|---|---|
| `M-x claude-pair` | Chat with Claude about the current project; reattaches a chat still open in the daemon (`C-u` starts a new one) |
| `M-x claude-pair-resume` | Reopen an earlier chat about the project, with its conversation |
| `M-x claude-pair-rewind` | Go back to before one of your messages: files and conversation |
| `M-x claude-pair-chats` | Every chat: project, branch, state, what waits, cost |
| `M-x claude-pair-worktree` | Make a git worktree on a new branch, with its own chat |
| `M-x claude-pair-plan` | Give Claude a task to plan first; you edit the plan in Org (`/plan` in the chat) |
| `M-x claude-pair-org-send-subtree` | Send the Org subtree at point as a task; the answer goes under it |
| `M-x claude-pair-magit-stage-claude` | Stage only the hunks you accepted from Claude |
| `M-x claude-pair-magit-draft-message` | In a commit message buffer: Claude writes the message from the diff and the chat |
| `M-x claude-pair-notes-share` | Share Claude's git notes with a remote: fetch theirs, push yours |
| `M-x claude-pair-ask` | Ask Claude about the region, or the function or line at point (`@claude …`) |
| `M-x claude-pair-review` | List every hunk waiting for your review |
| `M-x claude-pair-set-review-style` | Choose how Claude's edits wait for you: blocking, deferred, auto-accept |
| `M-x claude-pair-blame` | Say who wrote the line at point (`C-u`: every run of Claude's lines) |
| `M-x claude-pair-slash-refresh` | Read the slash commands again, after you add one |
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
| `C-c C-r` | Send your review of deferred edits to Claude now |
| `@` then `C-M-i`, or `C-c @` | Point Claude at a file, `@buffer`, `@region` or `@diagnostics` (see below) |
| `/` then `C-M-i` | A slash command: Claude Code's, yours, `/clear`, `/resume`, `/rewind` (see [Slash commands](#slash-commands)) |
| `M-p` / `M-n` | Step through messages you sent earlier |

In a message, `@` points Claude at something you have in Emacs:
`@src/geo.py` (any file of the project), `@buffer` (the buffer you were
last in), `@region` (the region you last had there) and `@diagnostics`
(that buffer's Flymake or Flycheck diagnostics). Complete them after `@`
with `completion-at-point` (`C-M-i`, or Corfu and Company as you type), or
pick one with `C-c @`. Your message stays as you wrote it; Claude also gets
what each mention points at: a file's path to read, a region's place and
code, a buffer's text when it has unsaved changes, diagnostics as
`file:line` lines. In the transcript, mentions are buttons that take you
there.

The header line shows the model, what Claude is doing, and the session's cost
so far. Each tool call is one line: `▸` while it runs, `✓` or `✗` when done.

## How Claude writes

Every chat tells Claude, in its system prompt, how to write
(`claude-pair-instructions`). The default: clear, simple English, with
short sentences and everyday words, the correct technical terms, and a few
plain words explaining a term that may be unfamiliar. Change it to
anything you like, or set it to "" for none; it applies to new chats.

## Asking about any code

Select some code, or put point in a function, and `M-x claude-pair-ask`:
`@claude (about lines 12-30 of geo.py): explain this`. The question goes
to the project's chat with the file, the lines and the code, so Claude sees
exactly what you point at. The answer streams into the chat and into a
note above the code, whole, wrapped to your window, so you can read it
without opening the chat. `[fold]` shows only its start (`[unfold]` the
rest; `M-x claude-pair-review-toggle-note` from the keyboard), and `[×]`
dismisses it. Ask for a change ("add error
handling here") and you get a proposed edit, reviewed as usual. Asking
never moves you: no tab switch, the chat is not selected, and a draft you
were typing in the chat stays. Bind it to a key you like, for example
`(keymap-global-set "C-c a" #'claude-pair-ask)`.

## Where Claude starts

The folder a chat starts in is its project: Claude Code reads its
instructions (`CLAUDE.md`) from there and every folder above, and Claude
may change files only inside it.

- In a repository: its root. With `claude-pair-project-root` set to
  `nearest-instructions`, the nearest folder at or above the file, inside
  the repository, with its own `CLAUDE.md`, `CLAUDE.local.md`,
  `.claude/CLAUDE.md` or `AGENTS.md` (a package of a monorepo); with `ask`,
  you choose between the two; or set it to a function of your own.
- Not in a repository: the nearest folder upwards holding one of
  `claude-pair-project-markers` (`CLAUDE.md`, `AGENTS.md`, `.claude/`,
  `package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `Makefile`, …),
  stopping before your home folder.
- Nothing found: you are asked, with the file's folder as the default.

Your home folder or `/` is never used without asking you first, since
Claude could then read and change every file there; a dotfiles repository
in your home folder asks too.

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
and into a note where the hunk was (`┃ @claude …`), with the whole answer;
`[fold]` shows only its first `claude-pair-review-note-lines` lines (3), and
`[×]` or `M-x claude-pair-review-dismiss-note` removes it.

Claude hears what happened to every hunk, with your notes, once the last
one is decided. The chat shows the edit as a block with its number of
hunks, where `y` applies all of them, `n` rejects all, `d` rejects all with
a note and `RET` shows the first hunk. Changes at most
`claude-pair-review-merge-gap` unchanged lines apart (2) make one hunk.

`M-x claude-pair-review` lists every hunk waiting for you, across files and
chats: file, hunk, line, size of the change, chat and how long it has
waited. `RET` shows the hunk, `a` applies it, `r` rejects it, `?` asks
Claude about it, `A` and `R` apply or reject its whole edit. The chat's
header line shows how many hunks wait.

How Claude's edits wait for you is `claude-pair-review-style`, or `M-x
claude-pair-set-review-style`:

| Style | What happens |
|---|---|
| `blocking` (default) | Claude waits for your decision on each edit |
| `deferred` | Claude is told the edit waits for your review and carries on. Your decisions are kept ("1 review result for Claude" in the header) and go to Claude with your next message, or alone with `C-c C-r` in the chat |
| `auto-accept` | Edits are applied as they arrive, still coloured as Claude's, and undone like any change |

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

## Claude's lines in git notes

Claude's lines keep their colour on this machine. With git notes they also
travel with the repository: to another clone, another machine, a
colleague.

- When you commit with Magit, a note on the new commit, in
  `refs/notes/claude-pair`, says which of the committed lines are Claude's:
  fingerprints of the lines and who wrote them, never the code, and no
  paths of your machine. Lines you did not commit are left out.
- When you open a file whose colours this machine does not know, the
  nearest note on it gives them back, matched by a diff, so later commits
  are fine.
- `M-x claude-pair-notes-write` writes the note for a commit made outside
  Emacs; `M-x claude-pair-notes-restore` reads notes for the file at hand.
- Notes stay local until you share them. A plain `git push` never sends
  them. `M-x claude-pair-notes-share` has a remote fetch them from now on,
  into `refs/notes/remotes/<remote>/claude-pair`, apart from yours, so a
  fetch or pull never overwrites notes you have not pushed; it then
  merges the two (yours win on the same commit) and pushes yours after
  asking. `claude-pair-notes-automatic` (t) turns the automatic part off.
- Other people and other editors see nothing of the notes unless they
  ask git for that ref: they are not files in the project, `git log`
  does not show them, and GitHub does not display them.

## Several chats at once

Several Claudes can work at once, each in its own git worktree, so their
edits never meet. A worktree is a project of its own, with its own chat.

- `M-x claude-pair-worktree` makes a worktree on a new branch, next to the
  repository (`claude-pair-worktree-directory`, by default
  `<repo>.worktrees/<name>`), and opens its chat.
- `M-x claude-pair-chats` lists every chat: project, branch, what Claude
  is doing, what waits for you, the cost. It refreshes itself while shown.
  `RET` opens a chat, `k` closes one, `w` makes a worktree, `D` removes
  one, `r` lists the hunks waiting. Chats still open in the daemon but
  not in this Emacs are listed too, and `RET` reattaches them.
- `M-x claude-pair-worktree-remove` removes a worktree (refusing one with
  changes not committed, unless `C-u`) and closes its chat; its branch
  stays.

## Plans you edit in Org

`M-x claude-pair-plan`, or `/plan TASK` in the chat, gives Claude a task in
plan mode: Claude reads what it needs and writes a plan, but changes
nothing. The plan opens in an Org buffer. Edit it as you like: reorder
steps, cut some, add your own. `C-c C-c` lets Claude go ahead with your
version; `C-c C-k` says no, with a reason Claude reads. Claude then works
from the plan you approved, and its edits still come to you for review.
Claude Code keeps approved plans in `~/.claude/plans/`.

## Org tasks and Embark

`M-x claude-pair-org-send-subtree` on an Org heading sends the subtree to
the project's chat as a task. When Claude is done, its answer goes under
the heading as a new subheading, in Org syntax. With `C-u`, Claude plans
first. The project is the one the Org file is in; for notes kept
elsewhere, you pick it.

With Embark, `@` in its action menu asks Claude about the target: a file
(mentioned in your question), a symbol (with where you are), or a region
(as `claude-pair-ask`, with the answer shown above it too).

## Commits with Magit

With Magit installed, `claude-pair-magit.el` loads by itself:

- `M-x claude-pair-magit-stage-claude` stages the hunks you accepted from
  Claude, and only those: the changes whose new lines are all Claude's
  coloured lines, and new files that are all Claude's. Your own changes
  stay unstaged, for a commit of their own. Lines Claude only removed
  cannot be told from yours, and files with unsaved changes are left
  alone. It needs only git, not Magit.
- `M-x claude-pair-magit-draft-message`, in the commit message buffer, has
  Claude write the message from the staged diff and what was said in the
  project's chat. Claude answers in a copy of the chat that is never saved,
  so the chat does not change. It uses `claude-pair-magit-model` (Haiku by
  default); `claude-pair-magit-draft-automatically` drafts whenever a
  commit buffer opens empty.
- No trailer is added to your commits. If you want one when the staged
  changes hold Claude's lines, set `claude-pair-magit-trailer`, for
  example to `"Co-Authored-By: Claude <noreply@anthropic.com>"`.

Neither command has a key; bind them where you like, for example in
`magit-status-mode-map` and `git-commit-mode-map`.

## Going back to an earlier turn

Every turn is a checkpoint. `M-x claude-pair-rewind`, or `/rewind` in the
chat, asks which of your messages to go back to before. Then:

- the files Claude changed in Emacs from then on go back to how they
  were, including your own later changes to them, as one step `undo` can
  take back in each buffer; a file Claude created is deleted;
- Claude forgets that message and everything after it;
- the chat shows the conversation up to there, and your message is back
  in the composer, to change and send again.

Checkpoints live in this Emacs: after Emacs restarts, a rewind takes back
the conversation only. Changes Claude made with shell commands are never
taken back.

## Slash commands

Type `/` at the start of a message and complete a command with
`completion-at-point` (`C-M-i`, or as you type with Corfu or Company).
You get Claude Code's own commands (`/compact`, `/context`, `/usage`,
`/model`, `/init` …), your commands in `.claude/commands/` and
`~/.claude/commands/`, skills and plugins, each with its description.
They run as Claude Code runs them.

`/clear` (or `/reset`, `/new`) starts a new chat, and the old one stays in
`M-x claude-pair-resume`. `/resume` reopens an earlier chat, and `/rewind`
goes back to an earlier turn. After you add
a command, `M-x claude-pair-slash-refresh` reads the list again.

## Reopening earlier chats

`M-x claude-pair-resume` lists the project's earlier chats, newest first,
with their title, age, number of messages and cost. The one you pick opens
with its conversation drawn again, and Claude goes on where it stopped,
remembering all of it. Claude Code keeps every conversation, so chats you
had with Claude Code in a terminal are in the list too.

When Emacs restarts, the daemon keeps your chats open. `M-x claude-pair`
in a project then reattaches to the chat that was open there, conversation
included. With `C-u` it starts a new chat instead.

## Code in the chat

The chat shows code the way Markdown means it, in your messages and in
Claude's answers, and while you type:

- `` `inline code` `` gets a code colour, and its backticks are hidden.
  They stay in the text, so copying keeps them. In the message you are
  typing they are only dimmed, so the cursor never jumps over them.
- A fenced block (```` ```python ````, ```` ```go ````, …) is coloured by
  that language's own major mode, on its own background, with the fence
  lines dimmed. The mode's hooks never run, so no language server or
  linter starts just to colour a snippet. A language with no mode in your
  Emacs keeps the background only; `claude-pair-markdown-modes` maps more
  names to modes.

While Claude writes, each finished line is formatted at once, and a block
is coloured as soon as its closing fence arrives.

## What Emacs tells Claude

Claude can ask Emacs for what it knows beyond the text of files. These
tools only read, so they never ask you:

| Tool | What Claude learns |
|---|---|
| `diagnostics` | A file's errors and warnings from Flymake or Flycheck, the language server's included, or those of every open file of the project |
| `xref` | Where a symbol is defined, or every place it is used, through Eglot, lsp-mode or the mode's own backend; without one, Claude is told to use grep |
| `imenu` | A file's outline: classes, functions, sections, with their lines |
| `selection` | Where you are: the file and line of your cursor, the lines on your screen, and the text you have selected |

A file Claude asks about is opened if it is not, with unsafe local
variables ignored, so its mode and checker can run.

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
itself after 10 minutes with no Emacs connected; `M-x claude-pair` then
reattaches to a chat that was still open.

### Windows

Emacs on Windows has no Unix sockets, so there the daemon listens on a
port of `127.0.0.1` only, and writes the port and a secret token to
`%LOCALAPPDATA%\claude-pair\daemon.json`. Emacs reads that file and sends
the token; a program without it is refused. `claude-pair-daemon-transport`
picks this (`tcp`) or a socket (`unix`); the default follows your system.
Stopping a turn works by message instead of a signal.

The Windows daemon is built (`make dist`) and its tests pass under Wine
(`make test-wine`), and the Emacs package passes its tests over TCP on
Linux (`make test-lisp-tcp`). It has not yet run on a real Windows: please
report what you find.

## Configuration

`M-x customize-group RET claude-pair` lists everything. The ones you are most
likely to change:

| Option | Default | What it does |
|---|---|---|
| `claude-pair-layout-tab` | `"Claude"` | Tab the chat opens in; nil keeps the current tab |
| `claude-pair-max-windows` | 5 | Most windows Claude's frame may have when Claude adds one |
| `claude-pair-min-windows` | 2 | Fewest windows Claude leaves when it closes one |
| `claude-pair-focus-guard-seconds` | 3 | How long after you use a window Claude leaves it alone |
| `claude-pair-project-root` | `vc` | Where a chat starts in a repository: `vc`, `nearest-instructions`, `ask`, or a function |
| `claude-pair-project-markers` | `CLAUDE.md`, `package.json`, … | What marks a project's root outside a repository |
| `claude-pair-review-style` | `blocking` | How Claude's edits wait for you: `blocking`, `deferred`, `auto-accept` |
| `claude-pair-review-autosave` | t | Save a buffer after applying Claude's edit, if it had no unsaved changes of yours |
| `claude-pair-review-merge-gap` | 2 | Unchanged lines between two changes up to which they make one hunk |
| `claude-pair-popup-style` | `auto` | The hunk popup: `auto`, `child-frame`, `inline`, or nil for never |
| `claude-pair-popup-delay` | 0.3 | Seconds in a hunk before its popup opens; nil only on `M-RET` |
| `claude-pair-author-color` | `"#d97757"` | Colour blended into Claude's lines; nil leaves the face to your theme |
| `claude-pair-author-tint` | 0.10 | How much of it to blend in |
| `claude-pair-attribution-ignore-whitespace` | t | A Claude line whose only change is whitespace keeps its colour |
| `claude-pair-attribution-persist` | t | Remember Claude's lines after a file is closed |
| `claude-pair-instructions` | simple English, correct technical terms | Standing instructions Claude follows in every answer; empty for none |
| `claude-pair-resume-limit` | 50 | Most earlier chats `claude-pair-resume` lists |
| `claude-pair-magit-model` | `"haiku"` | Model that drafts commit messages; nil for Claude Code's default |
| `claude-pair-magit-trailer` | nil | Trailer for commits holding Claude's lines, such as `Co-Authored-By: …`; none by default |
| `claude-pair-notes-automatic` | t | Write a git note on each Magit commit, and read notes on files you open |
| `claude-pair-worktree-directory` | `"{repo}.worktrees/{name}"` | Where `claude-pair-worktree` puts a new worktree |
| `claude-pair-tools-wait` | 3 | Seconds a diagnostics call waits for Flymake or Flycheck to finish |
| `claude-pair-markdown-modes` | common languages | Major modes for the languages named after ```` ``` ```` in the chat |
| `claude-pair-model` | nil | Model for new chats, such as `"opus"`; nil for Claude Code's default |
| `claude-pair-environment-variables` | credentials, provider, proxies | Variables each new chat takes from Emacs |
| `claude-pair-claude-command` | nil | Path of `claude`; nil looks on `exec-path` |
| `claude-pair-daemon-command` | nil | Command that runs the daemon; nil looks on `exec-path`, then in the checkout |
| `claude-pair-daemon-idle-timeout` | 600 | Seconds the daemon waits with no Emacs before it stops; 0 never |
| `claude-pair-chat-window-width` | 0.38 | Width of the chat window, as a fraction of the frame or in columns |
| `claude-pair-socket-path` | nil | The daemon's socket; nil for the default above |
| `claude-pair-daemon-transport` | `unix`, `tcp` on Windows | How Emacs reaches the daemon: a Unix socket, or a local port with a token (see [Windows](#windows)) |

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
make check    # go vet (Linux, macOS, Windows), gofmt, versions, byte-compile, checkdoc,
              # Go tests (race detector; the server's over TCP too), ERT tests over a socket and over TCP
              # (no test calls the model: they use daemon/bin/fakeclaude)
make test-wine  # the daemon's tests built for Windows, run under Wine
make test-lisp CLAUDE_PAIR_TEST_PACKAGES=~/.config/emacs/.local/straight/build-30.1
              # also the tests that need Magit and the like, from a directory of built packages
make dist     # static daemons for Linux, macOS and Windows, amd64 and arm64, with SHA256SUMS, in dist/
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
| `PHASE-1.org` … `PHASE-4.org` | The checklists of each phase, with automatic and visual tests |
| `.github/workflows/` | CI (`make check` on Linux and macOS, Emacs 29.1 and 30.1; the daemon's tests on Windows) and releases |

## License

GPL-3.0-or-later.
