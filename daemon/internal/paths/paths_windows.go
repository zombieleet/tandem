//go:build windows

package paths

import (
	"os"
	"path/filepath"
)

// DefaultRuntimeDir is %LOCALAPPDATA%\claude-pair, private to the user.
func DefaultRuntimeDir() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "claude-pair")
}

// DefaultSocketPath is the endpoint file: Emacs on Windows has no Unix
// sockets, so the daemon listens on a local TCP port.
func DefaultSocketPath() string {
	return filepath.Join(DefaultRuntimeDir(), "daemon.json")
}

// DefaultTCP says whether the daemon listens on TCP unless told otherwise.
const DefaultTCP = true
