# tandem

Work on code with Claude Code in Emacs. The full manual is in Emacs:
`C-h i m tandem` (run `make info` in a checkout first).

tandem is an independent project. Its old name was claude-pair. Anthropic
does not make it, endorse it or support it. Claude and Claude Code are
trademarks of Anthropic, PBC.

## How it works

tandem has two parts.

- **The daemon**, `tandemd`. A daemon is a program that runs in the
  background. It is written in Go. It runs your installed Claude Code
  (`claude`) in its headless stream-json mode.
- **The Emacs package.** Emacs is the client. It shows the chat and
  Claude's edits.

## What you can do

- Chat with Claude about a project. See its tool calls. Stop an answer.
- Allow or deny each command Claude wants to run.
- Review each edit in the file's own buffer, hunk by hunk. A hunk is one
  block of changed lines.
- Ask Claude about a hunk, or about any code, before you decide.
- See which lines Claude wrote. They keep a colour until someone edits them.
- Let Claude show you files in up to 5 windows. Claude never takes your
  cursor.
- Point Claude at files, buffers and regions with `@`.
- Let Claude ask Emacs for diagnostics, definitions, outlines and your
  selection.
- Open old chats again. Run slash commands. Go back to before any message.
  Files go back too.
- See code in the chat in colour.
- With Magit: stage only Claude's hunks. Let Claude write the commit
  message.
- Share Claude's lines with the repository in git notes.
- Plan in an Org buffer that you edit. Send Org subtrees as tasks. Ask
  from Embark.
- Run many Claudes at once, one for each git worktree. See them all in a
  dashboard.

## Requirements

- Emacs 29.1 or later.
- Claude Code 2.1.0 or later. `claude` must be on your `PATH`. You must be
  logged in, or use an API key, Amazon Bedrock or Google Vertex AI.
- Linux or macOS. Windows support is built and tested under Wine. It has
  not run on a real Windows yet. See [Windows](#windows).
- Go 1.26 or later, only if you build the daemon. Release builds need Go
  1.27.4 or later.

## Install

You need two things: the Emacs package in `lisp/` and the daemon,
`tandemd`.

### From a package archive

When tandem is on MELPA:

```elisp
(use-package tandem
  :ensure t
  :demand t
  :bind ("C-c C" . tandem))
```

The first time tandem needs its daemon, it asks to download it. It gets
the file for your system from the GitHub release of the same version.
`M-x tandem-install-daemon` does the same.

tandem checks the file before it keeps it. The package holds the SHA-256
of each daemon. It was written when the release was built. If the file
does not match, tandem refuses it. So a file that changed on the server or
on the way is not used.

The daemon goes into `~/.emacs.d/tandem/` (`tandem-daemon-directory`).
The manual is in `C-h i`.

### From a checkout

**The daemon.** Build it from a checkout:

```sh
git clone https://github.com/zombieleet/tandem ~/src/tandem
cd ~/src/tandem && make daemon      # daemon/bin/tandemd
```

The package finds a daemon built there. You can also download a built one
from the releases page. There is one for Linux, macOS and Windows (amd64
or arm64). Check it. Then put it on your `PATH` as `tandemd` (`tandemd.exe`
on Windows):

```sh
sha256sum -c --ignore-missing SHA256SUMS        # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
install -m 755 tandemd-0.4.0-linux-amd64 ~/.local/bin/tandemd
```

On macOS, a downloaded binary is in quarantine. Run `xattr -d
com.apple.quarantine ~/.local/bin/tandemd` to free it.

Sometimes Emacs does not see your shell's `PATH`. This is common for the
macOS app. Then set `tandem-daemon-command` to
`'("/full/path/to/tandemd")`. Set `tandem-claude-command` the same way if
`claude` is not found.

tandem looks for the daemon in this order:

1. `tandem-daemon-command`
2. `tandemd` on the `PATH`
3. the one `make daemon` built in the checkout
4. the one `tandem-install-daemon` installed

**The package.** This example has a key binding. `C-c` and a letter are
free for you. Pick any free one:

```elisp
(use-package tandem
  :load-path "~/src/tandem/lisp"
  :demand t
  :bind ("C-c C" . tandem))
```

Without `use-package`:

```elisp
(add-to-list 'load-path "~/src/tandem/lisp")
(require 'tandem)
(keymap-global-set "C-c C" #'tandem)
```

Load it at startup, as in the examples. Do not wait for first use.
Loading takes about 60 ms and starts no daemon. After that, tandem works
before you open a chat: Claude's lines get their colour back in files you
open, and commits get their git notes.

To try it and not change your configuration:

```sh
emacs -Q -L ~/src/tandem/lisp --eval "(require 'tandem)"
```

## Use

Run `M-x tandem` in any file of a project. The chat opens in a tab named
"Claude". Type after the `❯` prompt. Send with `C-c C-c`.

| Command | What it does |
|---|---|
| `M-x tandem` | Chat with Claude about this project. It joins a chat that is still open in the daemon. `C-u` starts a new one |
| `M-x tandem-resume` | Open an old chat about the project again, with its conversation |
| `M-x tandem-rewind` | Go back to before one of your messages: files and conversation |
| `M-x tandem-chats` | List every chat: project, branch, state, what waits, cost |
| `M-x tandem-worktree` | Make a git worktree on a new branch, with its own chat |
| `M-x tandem-plan` | Give Claude a task to plan first. You edit the plan in Org (`/plan` in the chat) |
| `M-x tandem-org-send-subtree` | Send the Org subtree at point as a task. The answer goes under it |
| `M-x tandem-magit-stage-claude` | Stage only the hunks you accepted from Claude |
| `M-x tandem-magit-draft-message` | In a commit message buffer: Claude writes the message from the diff and the chat |
| `M-x tandem-notes-share` | Share Claude's git notes with a remote: fetch theirs, push yours |
| `M-x tandem-ask` | Ask Claude about the region, or the function or line at point (`@claude …`) |
| `M-x tandem-do` | Tell Claude to change the region or the function at point. The change comes as hunks |
| `M-x global-tandem-suggest-mode` | Show grey code suggestions when you stop typing. `TAB` inserts. `M-x tandem-suggest-now` asks at once |
| `M-x tandem-review` | List every hunk that waits for your review |
| `M-x tandem-set-review-style` | Choose how Claude's edits wait for you: blocking, deferred, auto-accept |
| `M-x tandem-blame` | Say who wrote the line at point. `C-u`: every run of Claude's lines |
| `M-x tandem-slash-refresh` | Read the slash commands again, after you add one |
| `M-x tandem-connect` | Connect. Start the daemon if it is not running |
| `M-x tandem-daemon-status` | Show the daemon's version, pid, uptime and clients |
| `M-x tandem-events-buffer` | Show every message between Emacs and the daemon |
| `M-x tandem-disconnect` | Close the connection. The daemon keeps running |
| `M-x tandem-stop-daemon` | Stop the daemon |

In the chat buffer, type after the `❯` prompt:

| Key | What it does |
|---|---|
| `C-c C-c` | Send your message |
| `C-c C-k` | Stop Claude's answer. Your next message continues the conversation |
| `C-c C-p` | Answer Claude's oldest permission question from a menu |
| `C-c C-r` | Send your review of deferred edits to Claude now |
| `@` then `C-M-i`, or `C-c @` | Point Claude at a file, `@buffer`, `@region` or `@diagnostics` (see below) |
| `/` then `C-M-i` | A slash command: Claude Code's, yours, `/clear`, `/resume`, `/rewind` (see [Slash commands](#slash-commands)) |
| `M-p` / `M-n` | Go through messages you sent before |

In a message, `@` points Claude at something in Emacs:

- `@src/geo.py`: any file of the project.
- `@buffer`: the buffer you were last in.
- `@region`: the region you last had there.
- `@diagnostics`: that buffer's Flymake or Flycheck diagnostics.

Complete them after `@` with `completion-at-point` (`C-M-i`). Corfu and
Company complete as you type. Or pick one with `C-c @`.

Your message stays as you wrote it. Claude also gets what each mention
points at:

- for a file, the path to read;
- for a region, its place and code;
- for a buffer with unsaved changes, its text;
- for diagnostics, `file:line` lines.

In the transcript, mentions are buttons. They take you there.

The header line shows the model, what Claude is doing, and the cost of the
session. Each tool call is one line: `▸` when it runs, `✓` or `✗` when it
is done.

## How Claude writes

Every chat tells Claude how to write, in its system prompt
(`tandem-instructions`). The default is clear, simple English: short
sentences, common words and the correct technical terms. Claude explains a
term in a few words if you may not know it.

You can change it to any text. Set it to "" for none. It applies to new
chats.

## Asking about any code

Select some code, or put point in a function. Run `M-x tandem-ask`. You
see: `@claude (about lines 12-30 of geo.py): explain this`.

- The question goes to the project's chat with the file, the lines and the
  code. So Claude sees what you point at.
- The answer comes into the chat. It also comes into a note above the
  code. The note has the whole answer and fits your window. You can read
  it and not open the chat.
- `[fold]` shows only the start. `[unfold]` shows the rest. From the
  keyboard: `M-x tandem-review-toggle-note`. `[×]` removes the note.
- Ask for a change ("add error handling here") and you get a proposed
  edit. You review it as usual.
- Asking never moves you. No tab changes. The chat is not selected. A
  draft you were typing in the chat stays.

Bind it to a key you like. For example:
`(keymap-global-set "C-c a" #'tandem-ask)`.

## Telling Claude what to change

Put point in a function, or select some code. Run `M-x tandem-do`. Pick
one: Refactor, Simplify, Document, Type hints, Fix, Tests or Error
handling. Or type your own instruction ("rename main to run").

Claude gets the code, its place, and the errors Emacs reports there. It
makes the change with its edit tool. The change comes to you as hunks in
that buffer. You apply or reject them. A grey line above the code says
Claude is working, until it is done.

`C-u M-x tandem-do` makes Claude plan first. Add your own instructions to
`tandem-do-actions`.

## Suggestions as you type

Turn it on with `(global-tandem-suggest-mode 1)`. For one buffer, use
`M-x tandem-suggest-mode`.

- Stop typing for a moment. Claude suggests what comes next: the rest of
  the line, or a block. It shows in grey at the cursor.
- `TAB` inserts it. Any other key works as usual. If you type the start of
  the suggestion, the rest stays.
- `M-x tandem-suggest-now` asks at once.
- A suggestion takes one to three seconds. It goes through Claude Code
  with your login.
- It uses a small model (`tandem-suggest-model`, Haiku), no tools and a
  short system prompt. So each one costs a very small part of a cent.
- Only a stop after typing asks. A stop after moving does not.
- When the popup of Company or Corfu is open, `TAB` is theirs.

## Where Claude starts

A chat starts in a folder. That folder is its project. Claude Code reads
its instructions (`CLAUDE.md`) from there and from every folder above.
Claude may change files only inside it.

- **In a repository:** its root. You can change this with
  `tandem-project-root`:
  - `nearest-instructions`: the nearest folder, at or above the file and
    inside the repository, that has its own `CLAUDE.md`, `CLAUDE.local.md`,
    `.claude/CLAUDE.md` or `AGENTS.md`. This is good for a package of a
    monorepo.
  - `ask`: you choose between the two.
  - Or set it to your own function.
- **Not in a repository:** the nearest folder upwards that holds one of
  `tandem-project-markers` (`CLAUDE.md`, `AGENTS.md`, `.claude/`,
  `package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `Makefile`, …).
  The search stops before your home folder.
- **Nothing found:** tandem asks you. The default is the file's folder.

tandem never uses your home folder or `/` before it asks you. Claude could
read and change every file there. A dotfiles repository in your home
folder asks too.

## Reviewing edits

Claude never writes your files in secret. Each edit shows in the file's
buffer as a proposal. The proposal is split into hunks. A hunk is a block
of lines that change. Each hunk has a line above it ("hunk 2 of 3").

- The lines between hunks do not change. You can keep editing them.
- In a hunk, the old text has a line through it. The new text is below it,
  as real lines. You can scroll, move and read in them. They have the
  colours of the buffer's mode.
- Both are read-only until you decide.
- The new text is only for display. It is not an undo step. It does not
  mark the buffer as modified.
- Saving (`C-x C-s`) writes only your text. The proposal is taken out
  while your save hooks and formatters run.

With point on a hunk:

| Key | What it does |
|---|---|
| `C-c C-a` | Apply the hunk (one undo step) and move to the next |
| `C-c C-k` | Reject it. You can tell Claude why |
| `C-c '` | Ask Claude about it first (`@claude …`) |
| `C-u C-c C-a`, `C-u C-c C-k` | The same for every hunk of the edit |
| `n`, `p` | On the hunk's own text: the next or previous hunk |

### The popup

A small popup opens below a hunk when point stays in it for a moment
(`tandem-popup-delay`, 0.3 s), or when the mouse is over it. It says
"Claude · hunk 2 of 3 · file" and has the buttons ✓ Approve and ✗ Reject….

- In a graphical Emacs it is a child frame. It never takes focus, so you
  keep typing where you were.
- In a terminal, the hunk's banner line lights up. Its "apply" and
  "reject" parts are the buttons.
- `M-RET` opens it at once. It closes when point leaves the hunk.
- `tandem-popup-style` picks `child-frame`, `inline` or nil (never).

### Asking about a hunk

`C-c '`, or "@ Ask Claude…" in the popup, sends the edit back to Claude
with your question.

- Hunks you already decided keep their decision.
- The other hunks are not applied. Claude answers and proposes them again.
  It changes them if your question needs it.
- The answer comes into the chat. It also comes into a note where the hunk
  was (`┃ @claude …`), with the whole answer.
- `[fold]` shows only its first `tandem-review-note-lines` lines (3).
  `[×]` or `M-x tandem-review-dismiss-note` removes it.

### After you decide

Claude learns what happened to every hunk, with your notes. This happens
when the last hunk is decided.

The chat shows the edit as a block with its number of hunks. There, `y`
applies all hunks, `n` rejects all, `d` rejects all with a note, and `RET`
shows the first hunk.

Two changes make one hunk if at most `tandem-review-merge-gap` unchanged
lines (2) are between them.

### All waiting hunks

`M-x tandem-review` lists every hunk that waits for you, in all files and
chats. It shows the file, hunk, line, size of the change, chat and how
long it has waited.

- `RET` shows the hunk.
- `a` applies it. `r` rejects it.
- `?` asks Claude about it.
- `A` and `R` apply or reject its whole edit.

The chat's header line shows how many hunks wait.

### Review styles

`tandem-review-style` sets how Claude's edits wait for you. You can also
use `M-x tandem-set-review-style`.

| Style | What happens |
|---|---|
| `blocking` (default) | Claude waits for your decision on each edit |
| `deferred` | Claude is told the edit waits for your review. Claude continues. Your decisions are kept ("1 review result for Claude" in the header). They go to Claude with your next message, or alone with `C-c C-r` in the chat |
| `auto-accept` | Edits are applied when they arrive. They still have Claude's colour. You undo them like any change |

### Saving and safety

- An applied hunk is saved if the buffer had no unsaved changes of yours
  (`tandem-review-autosave`).
- If not, it stays unsaved. Claude is told that commands that read the
  file from disk still see the old version.
- Edits are checked against the live buffer, with unsaved changes. The
  rules are the same as in Claude Code's own Edit tool.
- Files are opened with unsafe local variables ignored.
- Only files inside the project can be edited.
- Sometimes the file is read again from disk when a proposal shows
  (`revert-buffer`, auto-revert). Then the proposal is removed. Claude is
  told to read the file again.

## Claude's lines keep their colour

Text that Claude wrote, in an edit you applied, keeps a light colour. The
colour is `tandem-author-color`, Claude's orange. It is mixed at
`tandem-author-tint` (10%) into your theme's background. It is computed
again when you change themes. In a graphical Emacs there is also a mark in
the left fringe. So colour is never the only sign.

A change of yours takes the colour off every line it touches:

- typing on the line;
- pasting Claude's text in another place (pasted text is yours).

These do not touch the line:

- opening a new line after one of Claude's lines;
- deleting whole lines around it.

Undo and redo bring the colour back, or take it away, with the text.

With `tandem-attribution-ignore-whitespace` (on), a line keeps its colour
if only whitespace changed. So new indentation and formatters do not
remove it.

The colours stay after you close the buffer, and after you close Emacs.

- Each save writes a fingerprint of every line of the file, and which
  lines are Claude's. A fingerprint is a short code made from the text.
- It goes under `tandem-attribution-directory`
  (`~/.cache/tandem/attribution`). Only you can read it.
- When you open the file again, tandem finds those lines where they are
  now. This works when lines were added above them.
- A line that changed has no colour any more.
- `tandem-attribution-persist` turns this off.

`M-x tandem-blame` says who wrote the line at point: "Claude (model) wrote
this line, in chat 1a2b3c4d, turn 3, 21 Nov 14:02, answering: "add
docstrings"". With `C-u`, it lists every run of Claude's lines in the
buffer. Each one is a link to its lines.

## Claude's windows

`M-x tandem` opens the chat in its own tab, named "Claude"
(`tandem-layout-tab`; nil keeps the current tab). Claude works only in the
frame and tab that show its chat. So your other tabs keep their layout.
When you look at another place, Claude is told that nothing can be shown.

Claude shows you files with its `open_file` tool, at the line it talks
about. These rules are always true, for anything Claude asks:

- **At most 5 windows** (`tandem-max-windows`), with the chat. Claude uses
  a window that already shows the file. If there is none, it splits the
  largest window. If it cannot, it uses again the window it used longest
  ago.
- **At least 2** (`tandem-min-windows`). Windows that Claude made are its
  own. It can close only those. It never closes yours or the chat.
- **Focus guard.** Claude never selects a window. It never changes or
  scrolls the window you are in. It does not touch a window you used in
  the last 3 seconds (`tandem-focus-guard-seconds`).
- `C-x 1` keeps the chat window.

Edit proposals open by the same rules. When the chat is not shown, an edit
proposal or permission question comes to you, because Claude waits for
you. There is one exception: you are in a tab that is not Claude's. Then
your tab does not change, and the echo area tells you to switch
(`C-x t o`).

## Claude's lines in git notes

Claude's lines keep their colour on this machine. With git notes they also
go with the repository: to another clone, another machine, another person.

- When you commit with Magit, the new commit gets a note in
  `refs/notes/tandem`. It says which of the committed lines are Claude's.
  It holds fingerprints of the lines and who wrote them. It never holds
  the code or paths of your machine. Lines you did not commit are not in
  it.
- When you open a file and this machine does not know its colours, the
  nearest note gives them back. They are matched by a diff, so later
  commits are fine.
- `M-x tandem-notes-write` writes the note for a commit made outside
  Emacs. `M-x tandem-notes-restore` reads notes for the current file.
- Notes stay local until you share them. A plain `git push` never sends
  them.
- `M-x tandem-notes-share` shares them with a remote:
  1. From now on, the remote's notes are fetched into
     `refs/notes/remotes/<remote>/tandem`, apart from yours. So a fetch or
     pull never overwrites notes you have not pushed.
  2. It merges the two. Yours win on the same commit.
  3. It asks you, then pushes yours.
- `tandem-notes-automatic` (t) turns the automatic part off.
- Other people and other editors see nothing of the notes if they do not
  ask git for that ref. The notes are not files in the project. `git log`
  does not show them. GitHub does not show them.

## Several chats at once

Many Claudes can work at once. Each one works in its own git worktree, so
their edits never meet. A worktree is its own project, with its own chat.

- `M-x tandem-worktree` makes a worktree on a new branch, next to the
  repository. The place is `tandem-worktree-directory`, by default
  `<repo>.worktrees/<name>`. It opens the chat of the worktree.
- `M-x tandem-chats` lists every chat: project, branch, what Claude is
  doing, what waits for you, the cost. It updates when it is shown.
  - `RET` opens a chat. `k` closes one.
  - `w` makes a worktree. `D` removes one.
  - `r` lists the hunks that wait.
  - Chats open in the daemon but not in this Emacs are listed too. `RET`
    joins them again.
- `M-x tandem-worktree-remove` removes a worktree and closes its chat. Its
  branch stays. It refuses a worktree with changes that are not committed,
  if you do not use `C-u`.

## Plans you edit in Org

`M-x tandem-plan`, or `/plan TASK` in the chat, gives Claude a task in
plan mode. Claude reads what it needs and writes a plan. It changes
nothing.

The plan opens in an Org buffer. Edit it as you like: move steps, cut
some, add your own.

- `C-c C-c` lets Claude start with your version.
- `C-c C-k` says no, with a reason that Claude reads.

Claude then works from the plan you approved. Its edits still come to you
for review. Claude Code keeps approved plans in `~/.claude/plans/`.

## Org tasks and Embark

`M-x tandem-org-send-subtree` on an Org heading sends the subtree to the
project's chat as a task. When Claude is done, its answer goes under the
heading as a new subheading, in Org syntax. With `C-u`, Claude plans
first. The project is the one that holds the Org file. For notes in
another place, you pick it.

With Embark and `(tandem-embark-mode 1)`, `@` in its action menu asks
Claude about the target:

- a file (it is mentioned in your question);
- a symbol (with where you are);
- a region (like `tandem-ask`; the answer shows above it too).

Turn it on when Embark is loaded:
`(with-eval-after-load 'embark (tandem-embark-mode 1))`, or in Doom
`(after! embark (tandem-embark-mode 1))`.

## Commits with Magit

The two commands below load `tandem-magit.el` when you first use them.
`(tandem-magit-mode 1)` also adds the trailer and the automatic draft to
every new commit message buffer, if you set their options.

- `M-x tandem-magit-stage-claude` stages the hunks you accepted from
  Claude, and only those. These are the changes whose new lines are all
  Claude's coloured lines, and new files that are all Claude's.
  - Your own changes stay unstaged, for their own commit.
  - It cannot tell lines that Claude only removed from yours.
  - It does not touch files with unsaved changes.
  - It needs only git, not Magit.
- `M-x tandem-magit-draft-message`, in the commit message buffer, makes
  Claude write the message. Claude uses the staged diff and what was said
  in the project's chat.
  - Claude answers in a copy of the chat. The copy is never saved, so the
    chat does not change.
  - It uses `tandem-magit-model` (Haiku by default).
  - `tandem-magit-draft-automatically` drafts each time a commit buffer
    opens empty.
- No trailer is added to your commits. You may want one when the staged
  changes hold Claude's lines. Then set `tandem-magit-trailer`, for
  example to `"Co-Authored-By: Claude <noreply@anthropic.com>"`.

The two commands have no key. Bind them where you like, for example in
`magit-status-mode-map` and `git-commit-mode-map`.

## Going back to an earlier turn

Every turn is a checkpoint. `M-x tandem-rewind`, or `/rewind` in the chat,
asks which of your messages to go back to. Then:

- The files Claude changed in Emacs after that go back to how they were.
  Your own later changes to them go back too. In each buffer this is one
  step that `undo` can take back. A file that Claude created is deleted.
- Claude forgets that message and everything after it.
- The chat shows the conversation up to there. Your message is back in the
  composer. You can change it and send it again.

Checkpoints live in this Emacs. After Emacs restarts, a rewind takes back
only the conversation. Changes Claude made with shell commands are never
taken back.

## Slash commands

Type `/` at the start of a message. The commands are listed at once, with
Company, or with `completion-at-point` if you do not use it.
`tandem-slash-popup` turns that off. Type more to see fewer commands.

You get:

- Claude Code's own commands (`/compact`, `/context`, `/usage`, `/model`,
  `/init` …);
- your commands in `.claude/commands/` and `~/.claude/commands/`;
- skills and plugins.

Each one has its description. They run as Claude Code runs them.

- `/clear` (or `/reset`, `/new`) starts a new chat. The old one stays in
  `M-x tandem-resume`.
- `/resume` opens an old chat again.
- `/rewind` goes back to an earlier turn.

After you add a command, `M-x tandem-slash-refresh` reads the list again.

## Reopening earlier chats

`M-x tandem-resume` lists the project's old chats, newest first. It shows
their title, age, number of messages and cost. The one you pick opens with
its conversation. Claude continues where it stopped and remembers all of
it.

Claude Code keeps every conversation. So chats you had with Claude Code in
a terminal are in the list too.

When Emacs restarts, the daemon keeps your chats open. `M-x tandem` in a
project then joins the chat that was open there, with its conversation.
With `C-u` it starts a new chat.

## Code in the chat

The chat shows code as Markdown means it. This is true in your messages,
in Claude's answers, and when you type.

- `` `inline code` `` gets a code colour. Its backticks are hidden. They
  stay in the text, so a copy keeps them. In the message you are typing
  they are only dimmed, so the cursor never jumps over them.
- A fenced block (```` ```python ````, ```` ```go ````, …) gets the colours
  of that language's own major mode. It has its own background. The fence
  lines are dimmed.
  - The mode's hooks never run. So no language server or linter starts
    only to colour a snippet.
  - A language with no mode in your Emacs keeps only the background.
  - `tandem-markdown-modes` maps more names to modes.

When Claude writes, each finished line is formatted at once. A block gets
its colours when its closing fence arrives.

## What Emacs tells Claude

Claude can ask Emacs for what it knows, more than the text of files. These
tools only read, so they never ask you:

| Tool | What Claude learns |
|---|---|
| `diagnostics` | A file's errors and warnings from Flymake or Flycheck, with those of the language server. Or those of every open file of the project |
| `xref` | Where a symbol is defined, or every place it is used. It uses Eglot, lsp-mode or the mode's own backend. If there is none, Claude is told to use grep |
| `imenu` | A file's outline: classes, functions, sections, with their lines |
| `selection` | Where you are: the file and line of your cursor, the lines on your screen, and the text you selected |

If Claude asks about a file that is not open, tandem opens it. Unsafe
local variables are ignored. Then its mode and checker can run.

When Claude shows you a place, those lines are highlighted. An example is
the place where something is defined. The highlight stays until you move
out of the lines, change them, or Claude shows another place.

Sometimes an xref lookup finds many places, such as every call of a
function.

- `M-g n` and `M-g p` (`next-error`, `previous-error`) go through them.
  Each one is highlighted.
- If Claude showed one of them, you continue from there.
- `M-x tandem-locations` lists them.
- With `repeat-mode` on, after `M-g n` you can press only `n` and `p`.

## Permission questions

Some tools need your approval: to run a command, to fetch a page, and
others. Then the question shows in the chat:

```
  ⏸ Claude wants to run:
      make test
    y allow once   a always allow Bash(make test)   n deny   d deny with a reason
```

Put point on the question and press the key.

- `a` adds the rule that is shown. Claude Code saves it in the project's
  `.claude/settings.local.json`. Its own "don't ask again" uses the same
  file.
- `d` asks what to tell Claude.
- If the chat is hidden, it comes up. The echo area says a question waits.
- Nothing is asked in the minibuffer in secret. So a wrong key in another
  place cannot approve a command.
- `M-x tandem-answer-permission` answers from any buffer. Bind it to a key
  if you like.

## Credentials

The daemon runs your installed `claude`. `claude` uses what you set it up
with: your Claude Code login, or an API key, Amazon Bedrock or Google
Vertex AI from the environment.

Each new chat takes the credential variables from Emacs, as they are at
that moment. The list is `tandem-environment-variables`:
`ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, the Bedrock and Vertex
switches, the proxies and a few more.

To switch, for example to an API key for some time:

1. `M-x setenv RET ANTHROPIC_API_KEY RET` and paste the key. It stays in
   that Emacs only. Nothing is written to disk.
2. Start a new chat: `C-u M-x tandem`.

`C-u M-x setenv RET ANTHROPIC_API_KEY RET` removes it again. The next new
chat uses your login. Open chats keep what they started with. Values are
never in the daemon's log.

## The daemon

The daemon listens on `$XDG_RUNTIME_DIR/tandem/daemon.sock`. On macOS it
is `$TMPDIR/tandem-<uid>/daemon.sock`. It logs to `daemon.log` in the same
directory. Only you must have access to that directory.

The daemon keeps running when Emacs closes. It stops after 10 minutes with
no Emacs connected. `M-x tandem` then joins a chat that was still open.

### Windows

Emacs on Windows has no Unix sockets. So there the daemon listens on a
port of `127.0.0.1` only. It writes the port and a secret token to
`%LOCALAPPDATA%\tandem\daemon.json`. Emacs reads that file and sends the
token. A program that has no token is refused.

`tandem-daemon-transport` picks this (`tcp`) or a socket (`unix`). The
default follows your system. Stopping a turn works by message, not by
signal.

What is tested:

- The Windows daemon is built (`make dist`).
- Its tests pass under Wine (`make test-wine`).
- The Emacs package passes its tests over TCP on Linux
  (`make test-lisp-tcp`).

It has not run on a real Windows yet. Please report what you find.

## Configuration

`M-x customize-group RET tandem` lists everything. You will most likely
change these:

| Option | Default | What it does |
|---|---|---|
| `tandem-layout-tab` | `"Claude"` | Tab the chat opens in; nil keeps the current tab |
| `tandem-max-windows` | 5 | Most windows Claude's frame may have when Claude adds one |
| `tandem-min-windows` | 2 | Fewest windows Claude leaves when it closes one |
| `tandem-focus-guard-seconds` | 3 | Seconds after you use a window in which Claude does not touch it |
| `tandem-project-root` | `vc` | Where a chat starts in a repository: `vc`, `nearest-instructions`, `ask`, or a function |
| `tandem-project-markers` | `CLAUDE.md`, `package.json`, … | What marks a project's root outside a repository |
| `tandem-review-style` | `blocking` | How Claude's edits wait for you: `blocking`, `deferred`, `auto-accept` |
| `tandem-review-autosave` | t | Save a buffer after applying Claude's edit, if it had no unsaved changes of yours |
| `tandem-review-merge-gap` | 2 | Two changes make one hunk if at most this many unchanged lines are between them |
| `tandem-popup-style` | `auto` | The hunk popup: `auto`, `child-frame`, `inline`, or nil for never |
| `tandem-popup-delay` | 0.3 | Seconds in a hunk before its popup opens; nil: only on `M-RET` |
| `tandem-author-color` | `"#d97757"` | Colour mixed into Claude's lines; nil leaves the face to your theme |
| `tandem-author-tint` | 0.10 | How much of it to mix in |
| `tandem-attribution-ignore-whitespace` | t | A Claude line keeps its colour if only whitespace changed |
| `tandem-attribution-persist` | t | Remember Claude's lines after a file is closed |
| `tandem-instructions` | simple English, correct technical terms | Instructions Claude follows in every answer; empty for none |
| `tandem-resume-limit` | 50 | Most old chats `tandem-resume` lists |
| `tandem-magit-model` | `"haiku"` | Model that writes commit messages; nil for Claude Code's default |
| `tandem-magit-trailer` | nil | Trailer for commits that hold Claude's lines, such as `Co-Authored-By: …`; none by default |
| `tandem-notes-automatic` | t | Write a git note on each Magit commit, and read notes on files you open |
| `tandem-worktree-directory` | `"{repo}.worktrees/{name}"` | Where `tandem-worktree` puts a new worktree |
| `tandem-tools-wait` | 3 | Seconds a diagnostics call waits for Flymake or Flycheck to finish |
| `tandem-markdown-modes` | common languages | Major modes for the languages named after ```` ``` ```` in the chat |
| `tandem-model` | nil | Model for new chats, such as `"opus"`; nil for Claude Code's default |
| `tandem-environment-variables` | credentials, provider, proxies | Variables each new chat takes from Emacs |
| `tandem-claude-command` | nil | Path of `claude`; nil looks on `exec-path` |
| `tandem-daemon-command` | nil | Command that runs the daemon; nil looks on `exec-path`, then in the checkout |
| `tandem-daemon-idle-timeout` | 600 | Seconds the daemon waits with no Emacs before it stops; 0 never |
| `tandem-chat-window-width` | 0.38 | Width of the chat window, as a fraction of the frame or in columns |
| `tandem-socket-path` | nil | The daemon's socket; nil for the default above |
| `tandem-daemon-transport` | `unix`, `tcp` on Windows | How Emacs reaches the daemon: a Unix socket, or a local port with a token (see [Windows](#windows)) |

## Troubleshooting

| You see | Do this |
|---|---|
| "…speaks protocol X, but the running tandemd speaks Y" | Answer `y` to restart it, or `M-x tandem-stop-daemon`. It happens after an upgrade. |
| "Cannot find tandemd" | `make daemon` in the checkout, or set `tandem-daemon-command`. |
| "…has mode 775, so other users can reach the socket" | `chmod 700` that directory, or set `tandem-socket-path` to a private one. |
| "claude … is too old" or not found | Update Claude Code, or set `tandem-claude-command`. |
| A changed key or login is not used | Start a new chat with `C-u M-x tandem`. |
| Anything else | `M-x tandem-events-buffer` shows every message. `daemon.log` is next to the socket. |

## Development

```sh
make check    # go vet (Linux, macOS, Windows), gofmt, versions, byte-compile, checkdoc,
              # Go tests (race detector; the server's over TCP too), ERT tests over a socket and over TCP
              # (no test calls the model: they use daemon/bin/fakeclaude)
make info     # the manual, doc/tandem.info; C-h i then finds it
make reference  # regenerate the manual's list of every command and option
make test-wine  # the daemon's tests built for Windows, run under Wine
make test-lisp TANDEM_TEST_PACKAGES=~/.config/emacs/.local/straight/build-30.1
              # also the tests that need Magit and the like, from a directory of built packages
make dist     # static daemons for Linux, macOS and Windows, amd64 and arm64, with SHA256SUMS, in dist/
make help     # every target
```

A release is a tag `vX.Y.Z`. It must match `;; Version:` in
`lisp/tandem.el` and `daemon/internal/version`. When you push the tag, the
daemons are built and published.

## Layout

| Path | Contents |
|---|---|
| `lisp/` | The Emacs package |
| `daemon/` | `tandemd`, in Go (`cmd/tandemd`, `internal/…`) |
| `doc/` | The manual (`tandem.texi`; `make info` builds it, `C-h i` finds it) and its generated reference |
| `protocol/PROTOCOL.md` | The rules for messages between the two parts |
| `SECURITY.md` | What tandem trusts, how each way in is protected, and how to report a problem |
| `test/` | ERT tests, shared helpers and the checkdoc runner |
| `daemon/internal/testutil/fakeclaude` | A program that stands in for Claude Code in the tests; it never calls a model |
| `.github/workflows/` | CI (`make check` on Linux and macOS, Emacs 29.1 and 30.1; the daemon's tests on Windows) and releases |

## License

GPL-3.0-or-later.
