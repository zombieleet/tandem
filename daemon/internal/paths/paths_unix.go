//go:build !windows

// Package paths says where the daemon's socket lives.
// Keep it in step with claude-pair-rpc-default-socket-path in lisp/claude-pair-rpc.el.
package paths

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultRuntimeDir is $XDG_RUNTIME_DIR/claude-pair, or <tmpdir>/claude-pair-<uid>
// when XDG_RUNTIME_DIR is unset or not absolute.
func DefaultRuntimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" && filepath.IsAbs(xdg) {
		return filepath.Join(xdg, "claude-pair")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("claude-pair-%d", os.Getuid()))
}

// DefaultSocketPath is daemon.sock inside DefaultRuntimeDir.
func DefaultSocketPath() string {
	return filepath.Join(DefaultRuntimeDir(), "daemon.sock")
}

// DefaultTCP says whether the daemon listens on TCP unless told otherwise.
const DefaultTCP = false
