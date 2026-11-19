# claude-pair protocol

Version **0.1.0**. This document is the contract between the Emacs client
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
4. With no clients connected, the daemon exits after its idle timeout
   (default 600 seconds, `--idle-timeout`, `0` disables it).

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
