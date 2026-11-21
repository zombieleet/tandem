// Package protocol holds the claude-pair protocol's constants and message types.
// See protocol/PROTOCOL.md.
package protocol

import (
	"strconv"
	"strings"
)

// Version is the protocol version this daemon speaks.
const Version = "0.17.0"

// JSON-RPC error codes, standard and claude-pair specific.
const (
	ParseError           = -32700
	InvalidRequest       = -32600
	MethodNotFound       = -32601
	InvalidParams        = -32602
	InternalError        = -32603
	IncompatibleProtocol = -32001
	NotInitialized       = -32002
	SessionBusy          = -32003
	UnknownSession       = -32004
	ClaudeUnavailable    = -32005
	UnknownRequest       = -32006
	Unauthorized         = -32007
)

// ParseVersion parses MAJOR.MINOR.PATCH.
func ParseVersion(s string) ([3]int, bool) {
	var v [3]int
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return v, false
	}
	for i, p := range parts {
		if p == "" || strings.TrimLeft(p, "0123456789") != "" {
			return v, false
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return v, false
		}
		v[i] = n
	}
	return v, true
}

// Compatible reports whether a client speaking version client can talk to a
// daemon speaking version daemon: the major numbers match and, while the
// major number is 0, the minor numbers match too.
func Compatible(client, daemon string) bool {
	a, okA := ParseVersion(client)
	b, okB := ParseVersion(daemon)
	if !okA || !okB || a[0] != b[0] {
		return false
	}
	return a[0] != 0 || a[1] == b[1]
}

// ClientInfo identifies the client in initialize.
type ClientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

// InitializeParams are the params of initialize.
type InitializeParams struct {
	ProtocolVersion *string        `json:"protocolVersion"`
	ClientInfo      *ClientInfo    `json:"clientInfo,omitempty"`
	Capabilities    map[string]any `json:"capabilities,omitempty"`
}

// ServerInfo identifies the daemon in the initialize result.
type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// InitializeResult is the result of initialize.
type InitializeResult struct {
	ProtocolVersion string         `json:"protocolVersion"`
	ServerInfo      ServerInfo     `json:"serverInfo"`
	PID             int            `json:"pid"`
	Capabilities    map[string]any `json:"capabilities"`
}

// StatusResult is the result of daemon/status.
type StatusResult struct {
	Version            string  `json:"version"`
	ProtocolVersion    string  `json:"protocolVersion"`
	PID                int     `json:"pid"`
	UptimeSeconds      int     `json:"uptimeSeconds"`
	Clients            int     `json:"clients"`
	Sessions           int     `json:"sessions"`
	SocketPath         string  `json:"socketPath"`
	IdleTimeoutSeconds float64 `json:"idleTimeoutSeconds"`
}
