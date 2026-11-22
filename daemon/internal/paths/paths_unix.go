//go:build !windows

// Package paths says where the daemon's socket lives.
// Keep it in step with tandem-rpc-default-socket-path in lisp/tandem-rpc.el.
package paths

import (
	"fmt"
	"os"
	"path/filepath"
)

// DefaultRuntimeDir is $XDG_RUNTIME_DIR/tandem, or <tmpdir>/tandem-<uid>
// when XDG_RUNTIME_DIR is unset or not absolute.
func DefaultRuntimeDir() string {
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" && filepath.IsAbs(xdg) {
		return filepath.Join(xdg, "tandem")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("tandem-%d", os.Getuid()))
}

// DefaultSocketPath is daemon.sock inside DefaultRuntimeDir.
func DefaultSocketPath() string {
	return filepath.Join(DefaultRuntimeDir(), "daemon.sock")
}

// DefaultTCP says whether the daemon listens on TCP unless told otherwise.
const DefaultTCP = false
