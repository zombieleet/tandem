# claude-pair protocol

Version **0.2.0**. This document is the contract between the Emacs client
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
responses and notifications. Both sides may send requests: the client calls
the daemon, and from version 0.2 the daemon calls the client for reviews,
permission questions and Emacs tools.

## Lifecycle

1. The client connects to the socket. If nothing listens there, it starts the
   daemon with `claude-paird --detach --socket <path>`, which returns once the
   socket accepts connections.
2. The client sends `initialize`. Every other request before a successful
   `initialize` fails with `-32002`.
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
`-32001` with `data: {daemonProtocolVersion, daemonVersion}`.

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
`claudePath` (absolute path of the `claude` command), optional `model`.

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
       --permission-prompts none --disallowedTools Edit,Write,NotebookEdit
       [--model M] (--session-id ID | --resume ID)
```

The first start uses `--session-id`; every later start uses `--resume`. In
0.2, tools that would ask for permission are denied, and the built-in
writing tools are off, because Emacs will own every write.

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

Every turn ends with a `result` (or an `error`) followed by `status` `idle`.
Events from subagents are left out; the subagent's own tool call shows instead.

### `shutdown` (client → daemon)

No params. Result `{ok: true}`. After sending the result the daemon closes
every connection, removes its socket and exits.

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
