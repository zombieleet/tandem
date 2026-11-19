package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/victory/claude-pair/daemon/internal/framing"
)

// binary is the daemon built once for these tests: --detach re-executes it.
var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cpd-bin-")
	if err != nil {
		panic(err)
	}
	binary = filepath.Join(dir, "claude-paird")
	if out, err := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		panic(fmt.Sprintf("go build: %v\n%s", err, out))
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func paird(t *testing.T, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	cmd := exec.Command(binary, args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return out.String(), errb.String(), code
}

func privateDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "cpd-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func call(t *testing.T, nc net.Conn, r *framing.Reader, id int, method string, params any) map[string]json.RawMessage {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	nc.Write(framing.Frame(body))
	nc.SetReadDeadline(time.Now().Add(3 * time.Second))
	reply, err := r.Read()
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	json.Unmarshal(reply, &m)
	return m
}

func TestVersion(t *testing.T) {
	out, _, code := paird(t, "--version")
	if code != 0 || !regexp.MustCompile(`^claude-paird \d+\.\d+\.\d+ \(protocol 0\.1\.0\)\n$`).MatchString(out) {
		t.Fatalf("code %d, output %q", code, out)
	}
}

func TestDetach(t *testing.T) {
	dir := privateDir(t)
	path := filepath.Join(dir, "d.sock")
	out, errOut, code := paird(t, "--detach", "--socket", path, "--idle-timeout", "30")
	m := regexp.MustCompile(`^ready (\d+) (.+)\n$`).FindStringSubmatch(out)
	if code != 0 || m == nil || m[2] != path {
		t.Fatalf("code %d, stdout %q, stderr %q", code, out, errOut)
	}

	out, _, code = paird(t, "--detach", "--socket", path)
	if code != 0 || out != "already running "+path+"\n" {
		t.Fatalf("second --detach: code %d, output %q", code, out)
	}

	nc, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	r := framing.NewReader(nc)
	init := call(t, nc, r, 1, "initialize", map[string]string{"protocolVersion": "0.1.0"})
	var result struct{ PID int }
	json.Unmarshal(init["result"], &result)
	if fmt.Sprint(result.PID) != m[1] {
		t.Fatalf("pid %d, launcher said %s", result.PID, m[1])
	}
	call(t, nc, r, 2, "shutdown", nil)
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Lstat(path); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the socket was not removed")
		}
		time.Sleep(20 * time.Millisecond)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "daemon.log"))
	if !strings.Contains(string(log), "listening") {
		t.Fatalf("log does not mention listening:\n%s", log)
	}
}

func TestDetachReportsUnsafeDir(t *testing.T) {
	dir := privateDir(t)
	os.Chmod(dir, 0o755)
	_, errOut, code := paird(t, "--detach", "--socket", filepath.Join(dir, "d.sock"))
	if code != 1 || !strings.Contains(errOut, "other users can reach the socket") {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
}

func TestBadArguments(t *testing.T) {
	for _, args := range [][]string{
		{"--idle-timeout", "soon"},
		{"--log-level", "loud"},
		{"--no-such-flag"},
		{"stray"},
	} {
		_, errOut, code := paird(t, args...)
		if code != 2 || errOut == "" {
			t.Errorf("%v: code %d, stderr %q", args, code, errOut)
		}
	}
	_, errOut, _ := paird(t, "--idle-timeout", "soon")
	if !strings.Contains(errOut, "--idle-timeout needs a number of seconds") {
		t.Errorf("stderr %q", errOut)
	}
}

func TestHelp(t *testing.T) {
	_, errOut, code := paird(t, "--help")
	if code != 0 || !strings.Contains(errOut, "Usage: claude-paird") {
		t.Fatalf("code %d, output %q", code, errOut)
	}
}
