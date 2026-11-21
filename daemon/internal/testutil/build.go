// Package testutil helps the daemon's tests.
package testutil

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// Binary returns a test program called name, built from the package pkg
// into dir. With CPD_TEST_BINARIES set, it is taken from that directory
// instead, built beforehand: under Wine there is no go command to build it.
func Binary(dir, name, pkg string) (string, error) {
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if prebuilt := os.Getenv("CPD_TEST_BINARIES"); prebuilt != "" {
		path := filepath.Join(prebuilt, name)
		if _, err := os.Stat(path); err != nil {
			return "", fmt.Errorf("CPD_TEST_BINARIES has no %s: %w", name, err)
		}
		return path, nil
	}
	path := filepath.Join(dir, name)
	if out, err := exec.Command("go", "build", "-o", path, pkg).CombinedOutput(); err != nil {
		return "", fmt.Errorf("building %s: %v\n%s", pkg, err, out)
	}
	return path, nil
}
