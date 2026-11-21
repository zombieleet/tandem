# claude-pair protocol

Version **0.9.0**. This document is the contract between the Emacs client
(`lisp/`) and the daemon `claude-paird` (`daemon/`). Either side can be
replaced as long as it follows this document.

## Transport

- **POSIX:** a Unix domain socket. The default path is
  `$XDG_RUNTIME_DIR/claude-pair/daemon.sock`. When `XDG_RUNTIME_DIR` is unset
  or not absolute, it is `<tmpdir>/claude-pair-<uid>/daemon.sock`, where
  `<tmpdir>` is `$TMPDIR` or `/tmp`.
- The directory holding the socket must belong to the user and must not be
  readable, writable or searchable by anyone else (mode `0700`). The daemon
  creates it with that mode, and refuses to start in an existing directory
  that is less private. The socket itself is mode `0600`.
- The path must fit in 103 bytes (the macOS limit for socket paths).
- Windows (TCP on `127.0.0.1` with a token) is specified in a later version.

## Framing

Each message is a header section followed by a JSON body, as in the
Language Server Protocol:

```
Content-Length: <bytes>\r\n
\r\n
<body>
```

- `Content-Length` is the body length in **bytes** of its UTF-8 encoding.
- Header names are case-insensitive. Other headers are allowed and ignored.
- A header section without `Content-Length`, or with a value that is not a
  decimal number, is a fatal framing error: the receiver sends a `-32700`
  error with `id: null` and closes the connection.
- A body that is not valid JSON gets a `-32700` error with `id: null`. The
  connection stays open, because the length told the receiver where the next
  message starts.

## Messages

Bodies are [JSON-RPC 2.0](https://www.jsonrpc.org/specification) requests,
responses and notifications. Both sides may send requests.

Either side may cancel a request it sent with the notification
`$/cancelRequest` `{id}`, as in the Language Server Protocol. The receiver
stops the work and answers `-32800`. Closing the connection cancels every
request the receiver is still working on.

## Lifecycle

1. The client connects to the socket. If nothing listens there, it starts the
   daemon with `claude-paird --detach --socket <path>`, which returns once the
   socket accepts connections.
2. The client sends `initialize`. Every other request before a successful
   `initialize` fails with `-32002`, except `shutdown`, so a client can stop a
   daemon whose protocol it does not speak (from 0.4; older daemons need
   SIGTERM, which they handle like `shutdown`).
3. The connection stays open for as long as the client wants it.
4. With no clients connected and no turn running, the daemon exits after its
   idle timeout (default 600 seconds, `--idle-timeout`, `0` disables it).
   Sessions survive a client disconnecting; a client that sends
   `session/prompt` to an existing session follows it again.

## Methods

### `initialize` (client → daemon)

Params:

| Field | Type | Notes |
|---|---|---|
| `protocolVersion` | string | Required. `MAJOR.MINOR.PATCH` |
| `clientInfo` | `{name, version}` | Optional |
| `capabilities` | object | Optional. `childFrames: boolean`, `maxWindows: number` |

Result:

| Field | Type |
|---|---|
| `protocolVersion` | string |
| `serverInfo` | `{name: "claude-paird", version}` |
| `pid` | number |
| `capabilities` | object (empty in 0.1) |

Versions are compatible when the major numbers match and, while the major
number is `0`, the minor numbers match too. Otherwise the daemon answers
`-32001` with `data: {daemonProtocolVersion, daemonVersion, pid}`.

### `daemon/status` (client → daemon)

No params. Result:

| Field | Type |
|---|---|
| `version` | string |
| `protocolVersion` | string |
| `pid` | number |
| `uptimeSeconds` | number |
| `clients` | number |
| `sessions` | number |
| `socketPath` | string |
| `idleTimeoutSeconds` | number |

### `session/new` (client → daemon)

Params: `cwd` (absolute path of an existing directory, the project root),
`claudePath` (absolute path of the `claude` command), optional `model`,
optional `env`: an object from variable names to a string, which sets the
variable for this session's `claude`, or `null`, which removes it. Every
other variable comes from the daemon's own environment. A name that is empty
or holds `=` fails with `-32602`. Values are typically credentials: the
daemon never logs them.

The daemon runs `claudePath --version` and refuses Claude Code older than
2.1.0 with `-32005`. Result: `{sessionId, claudeVersion}`. The session id is a
UUID that Claude Code also uses, so `claude --resume <sessionId>` finds the
same conversation. The calling client follows the session. No `claude`
process starts until the first prompt.

### `session/prompt` (client → daemon)

Params: `sessionId`, `text`. Result `{ok: true}` once the message is written
to Claude Code; everything after that arrives as `session/update`. Fails with
`-32003` while a turn is running and `-32004` for an unknown session. The
calling client follows the session.

Each session runs one process:

```
claude -p --input-format stream-json --output-format stream-json --verbose
       --include-partial-messages --permission-mode default
       --disallowedTools Edit,Write,NotebookEdit
       --mcp-config '{"mcpServers":{"emacs":{"type":"stdio",
           "command":"<claude-paird>","args":["mcp","--socket",S,"--session",ID],
           "timeout":86400000}}}'
       --permission-prompt-tool mcp__emacs__permission
       --allowedTools mcp__emacs__edit_file,mcp__emacs__write_file,
                      mcp__emacs__open_file,mcp__emacs__close_window,mcp__emacs__list_windows
       --append-system-prompt "<how files change and windows work in claude-pair>"
       [--model M] (--session-id ID | --resume ID)
```

`<claude-paird>` is `/proc/<daemon pid>/exe` on Linux, so a helper is always
the daemon's own binary even after an upgrade replaced the file, and the
executable's path elsewhere.

The first start uses `--session-id`; every later start uses `--resume`. The
built-in writing tools are off, because Emacs will own every write. The
user's own MCP servers and settings still load. The 24-hour per-server
`timeout` lets a permission question wait for the user, and overrides a
shorter `MCP_TOOL_TIMEOUT`.

### `session/cancel` (client → daemon)

Params: `sessionId`. Result `{cancelled: boolean}`. The daemon sends SIGINT
to `claude`, which ends the turn and exits; the next prompt resumes the
session in a new process.

### `session/close` (client → daemon)

Params: `sessionId`. Stops `claude` and forgets the session. Result `{ok: true}`.

### `session/update` (daemon → client, notification)

Params: `{sessionId, update}`. `update.kind` is one of:

| kind | Fields | Meaning |
|---|---|---|
| `status` | `state`: `starting`, `running`, `requesting`, `cancelling`, `idle` | What the session is doing |
| `init` | `model`, `claudeVersion`, `cwd`, `permissionMode`, `slashCommands` | Claude Code started |
| `text` | `delta` | More of Claude's answer |
| `tool` | `id`, `name`, `title`, `status` (`started`, `done`, `error`), `durationMs` when finished | A tool call; `title` is one line such as `Read src/api.ts` |
| `todo` | `items`: `[{content, status}]` | Claude's todo list, replaced whole |
| `result` | `subtype`, `isError`, `cancelled`, `message`, `durationMs`, `numTurns`, `costUsd`, `sessionCostUsd`, `usage`, `permissionDenials` | The turn ended; `costUsd` is this turn's cost |
| `error` | `message`, `stderr`, `exitCode` | `claude` stopped unexpectedly |
| `permission` | `requestId`, `state`, and the fields below | A permission question (see below) |
| `edit` | `requestId`, `state`, and the fields below | A proposed edit (see below) |

Every turn ends with a `result` (or an `error`) followed by `status` `idle`.
Events from subagents are left out; the subagent's own tool call shows instead.

## Permission questions

Claude Code asks before running a tool that needs approval. It does so by
calling the permission tool of the MCP helper, `claude-paird mcp`, which it
starts from `--mcp-config`. The helper connects to the daemon's socket and
sends `initialize` with `capabilities: {role: "mcp-helper", sessionId}`.
Helpers do not count as clients, neither in `daemon/status` nor for the idle
timeout.

1. The helper sends `helper/permission` `{sessionId, toolName, input,
   toolUseId}` and waits.
2. The daemon picks who answers: the client that sent the session's last
   prompt if it is still connected, otherwise any client that follows the
   session. When none is connected, it denies at once.
3. Followers get `session/update` with `kind: "permission"`, `state:
   "pending"`, `requestId`, `toolName`, `toolUseId`, `input`, `title` (one
   line, as for tool calls) and `alwaysRule` (the rule "always allow" adds,
   such as `Bash(make test)`).
4. The client answers with `permission/answer` `{requestId, decision:
   "allow" | "deny", always, message}`. A request that is no longer pending
   fails with `-32006`.
5. Followers get `state: "answered"` with `decision`, `always` and `message`.
   A request is instead `state: "withdrawn"` with a `reason` when the turn is
   cancelled, the session closes, the daemon stops, or Claude Code abandons
   the call.
6. The helper returns the decision to Claude Code as one text block of JSON:
   `{"behavior":"allow","updatedInput":...}` or
   `{"behavior":"deny","message":...}`. For "always", the allow carries
   `updatedPermissions` with an `addRules` entry for `localSettings`, so
   Claude Code applies the rule at once and saves it in the project's
   `.claude/settings.local.json`.

"Always allow" adds the narrowest rule that covers the call: the exact Bash
command, the WebFetch domain (`WebFetch(domain:example.com)`), or else the
whole tool. Claude Code itself still asks again for Bash commands with
output redirection such as `>>`, whatever the rules say.

## Edits

Claude Code's built-in Edit, Write and NotebookEdit are off. Claude edits
through the helper's `edit_file` and `write_file` tools instead, which take
the same inputs as the built-in Edit (`file_path`, `old_string`,
`new_string`, `replace_all`) and Write (`file_path`, `content`). They are in
`--allowedTools`, so Claude Code asks no permission question for them: the
review itself is the question, and no permission rule can skip it.

1. The helper sends `helper/edit` `{sessionId, kind: "edit" | "write",
   filePath, oldString, newString, replaceAll, content}` and waits.
2. The daemon refuses, as an error result Claude reads, a path that is not
   absolute or not inside the session's directory (symbolic links are
   resolved), and an edit whose old and new strings are the same.
3. The daemon sends the notification `edit/propose` `{requestId, sessionId,
   kind, filePath, oldString, newString, replaceAll, content}` to the client
   that answers for the session (as for permission questions), and followers
   get `session/update` `kind: "edit"`, `state: "pending"`, `requestId`,
   `editKind`, `filePath`, `relPath`, `title`.
4. The client checks the edit against the file's live buffer, shows it, and
   answers with `edit/answer` `{requestId, outcome: "applied" | "rejected" |
   "partial" | "question" | "deferred" | "error", message, saved, created,
   hunks}`. `deferred` means the user reviews the edit later: Claude is
   told it is not applied yet and carries on; the client keeps the
   proposal and reports the decisions in a later prompt of its own. A client may
   split an edit into hunks for the user to decide one by one; `hunks` then
   lists each one as `{index, line, oldLines, newLines, decision:
   "applied" | "rejected" | "error" | "asked" | "undecided", note, saved}`,
   where `line` is where the hunk started when proposed. `partial` means
   some hunks were applied and some not, and requires `hunks`. `question`
   means the user asked about one hunk (`asked`, its note the question)
   before deciding the rest (`undecided`, not applied); it requires
   `hunks` and the question as `message`, and Claude reads it as a normal
   result asking it to answer and propose what is still wanted again. Only the client the edit was proposed
   to may answer; others get `-32006`. The client's error messages follow the
   built-in Edit tool's: `String to replace not found in file.`, `Found N
   matches of the string to replace, but replace_all is false. …`.
5. Followers get `state` equal to the outcome, with `message`, `saved`,
   `created` and `hunks`. Claude gets the outcome as the tool's result: an error result
   for a rejection, with the user's note, or for an error.
6. A cancelled turn, a closed session, a stopping daemon or a departed helper
   withdraws the edit: the reviewing client gets `edit/withdraw` `{requestId,
   reason}` and followers get `state: "withdrawn"`.

## Windows

Claude shows the user files through three more helper tools, in
`--allowedTools` because they change only what the user sees:

| Tool | Inputs |
|---|---|
| `open_file` | `path` (absolute, or relative to the project), `line` (optional, from 1) |
| `close_window` | `window`, an id from `list_windows` or `open_file` |
| `list_windows` | none |

1. The helper sends `helper/emacs` `{sessionId, tool, args}` and waits.
2. For `open_file` the daemon makes `path` absolute and refuses, as an error
   result, one outside the session's directory (symbolic links resolved).
3. The daemon sends the notification `tool/call` `{requestId, sessionId,
   tool, args, root}` to the client that answers for the session; `root` is
   the session's directory.
4. The client applies its window rules and answers with `tool/result`
   `{requestId, text, isError}`. Only the client the call went to may
   answer; others get `-32006`. `text` is what Claude reads, so it says what
   happened and why, such as "Window 2 is the user's, so it stays open".
5. If the client does not answer within 30 seconds, or disconnects first,
   Claude gets an error result saying so.

The window rules live in the client, not the daemon; the Emacs client's
are described in its README.

### `shutdown` (client → daemon)

No params. Result `{ok: true}`. After sending the result the daemon closes
every connection, removes its socket and exits. Accepted before
`initialize`.

## Error codes

| Code | Meaning |
|---|---|
| `-32700` | Parse error: bad framing or invalid JSON |
| `-32600` | Invalid request: not a JSON-RPC 2.0 message |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |
| `-32001` | Incompatible protocol version |
| `-32002` | Not initialized |
| `-32003` | Session busy: a turn is running |
| `-32004` | Unknown session |
| `-32005` | Claude Code unavailable: missing, not executable, too old, or failed to start |
| `-32006` | Unknown permission request: answered or withdrawn already |
| `-32800` | Request cancelled with `$/cancelRequest` |
