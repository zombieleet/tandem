package session

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/victory/claude-pair/daemon/internal/protocol"
)

// MinClaudeVersion is the oldest Claude Code the daemon accepts. Development
// and the live checks used 2.1.327.
const MinClaudeVersion = "2.1.0"

// UnavailableError means the claude command is missing, unusable or too old.
type UnavailableError struct{ msg string }

func (e *UnavailableError) Error() string { return e.msg }

func unavailable(format string, a ...any) error {
	return &UnavailableError{fmt.Sprintf(format, a...)}
}

var versionPattern = regexp.MustCompile(`^(\d+\.\d+\.\d+)`)

type cachedVersion struct {
	modTime time.Time
	version string
}

var (
	versionMu    sync.Mutex
	versionCache = map[string]cachedVersion{}
)

// CheckClaude runs "PATH --version" and returns the version if PATH is an
// absolute path to a Claude Code at least MinClaudeVersion. Results are
// cached until the file changes.
func CheckClaude(path string) (string, error) {
	if path == "" {
		return "", unavailable("no claude command given; install Claude Code or set claude-pair-claude-command")
	}
	if !filepath.IsAbs(path) {
		return "", unavailable("the claude command must be an absolute path, got %q", path)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", unavailable("cannot use claude at %s: %v", path, err)
	}
	// Windows has no executable bit: any regular file may be a program.
	if info.IsDir() || (runtime.GOOS != "windows" && info.Mode().Perm()&0o111 == 0) {
		return "", unavailable("%s is not an executable file", path)
	}

	versionMu.Lock()
	cached, ok := versionCache[path]
	versionMu.Unlock()
	if ok && cached.modTime.Equal(info.ModTime()) {
		return cached.version, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "--version").Output()
	if err != nil {
		return "", unavailable("%s --version failed: %v", path, err)
	}
	m := versionPattern.FindStringSubmatch(strings.TrimSpace(string(out)))
	if m == nil {
		return "", unavailable("%s --version printed %q, which is not a version", path, strings.TrimSpace(string(out)))
	}
	version := m[1]
	if !atLeast(version, MinClaudeVersion) {
		return "", unavailable("Claude Code %s is too old; claude-pair needs %s or later (run claude update)", version, MinClaudeVersion)
	}
	versionMu.Lock()
	versionCache[path] = cachedVersion{modTime: info.ModTime(), version: version}
	versionMu.Unlock()
	return version, nil
}

func atLeast(version, minimum string) bool {
	a, okA := protocol.ParseVersion(version)
	b, okB := protocol.ParseVersion(minimum)
	if !okA || !okB {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return true
}
