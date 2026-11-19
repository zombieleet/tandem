// Package paths says where the daemon's socket lives.
// Keep it in step with claude-pair-rpc-default-socket-path in lisp/claude-pair-rpc.el.
package paths

import (
	"fmt"
	"os"
	"path/filepath"
)

// MaxSocketPathBytes is the macOS limit: 104 bytes including the terminating NUL.
const MaxSocketPathBytes = 103

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
