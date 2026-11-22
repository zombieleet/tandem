package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/victory/tandem/daemon/internal/testutil"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/victory/tandem/daemon/internal/endpoint"
	"github.com/victory/tandem/daemon/internal/framing"
	"github.com/victory/tandem/daemon/internal/protocol"
)

// binary is the daemon built once for these tests: --detach re-executes it.
var binary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cpd-bin-")
	if err != nil {
		panic(err)
	}
	if binary, err = testutil.Binary(dir, "tandemd", "."); err != nil {
		panic(err)
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
	want := regexp.MustCompile(`^tandemd \d+\.\d+\.\d+ \(protocol ` + regexp.QuoteMeta(protocol.Version) + `\)\n$`)
	if code != 0 || !want.MatchString(out) {
		t.Fatalf("code %d, output %q", code, out)
	}
}

func TestDetach(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Run("socket", func(t *testing.T) { testDetach(t, false) })
	}
	t.Run("tcp", func(t *testing.T) { testDetach(t, true) })
}

func testDetach(t *testing.T, tcp bool) {
	dir := privateDir(t)
	path := filepath.Join(dir, "d.sock")
	if tcp {
		path = filepath.Join(dir, "d.json")
	}
	transport := "--tcp=" + fmt.Sprint(tcp)
	out, errOut, code := paird(t, "--detach", transport, "--socket", path, "--idle-timeout", "30")
	m := regexp.MustCompile(`^ready (\d+) (.+)\n$`).FindStringSubmatch(out)
	if code != 0 || m == nil || m[2] != path {
		t.Fatalf("code %d, stdout %q, stderr %q", code, out, errOut)
	}

	out, _, code = paird(t, "--detach", transport, "--socket", path)
	if code != 0 || out != "already running "+path+"\n" {
		t.Fatalf("second --detach: code %d, output %q", code, out)
	}

	nc, token, err := endpoint.Dial(path, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	if tcp != (token != "") {
		t.Fatalf("token %q over tcp=%v", token, tcp)
	}
	r := framing.NewReader(nc)
	init := call(t, nc, r, 1, "initialize", map[string]string{"protocolVersion": protocol.Version, "token": token})
	var result struct{ PID int }
	json.Unmarshal(init["result"], &result)
	if fmt.Sprint(result.PID) != m[1] {
		t.Fatalf("pid %d, launcher said %s (%s)", result.PID, m[1], init)
	}
	call(t, nc, r, 2, "shutdown", map[string]string{"token": token})
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Lstat(path); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the socket or endpoint file was not removed")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// The log may still be open on Windows for a moment after the exit.
	var log []byte
	for i := 0; i < 50 && !strings.Contains(string(log), "listening"); i++ {
		log, _ = os.ReadFile(filepath.Join(dir, "daemon.log"))
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(string(log), "listening") {
		t.Fatalf("log does not mention listening:\n%s", log)
	}
}

func TestDetachReportsUnsafeDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("about Unix file modes")
	}
	dir := privateDir(t)
	os.Chmod(dir, 0o755)
	_, errOut, code := paird(t, "--detach", "--tcp=false", "--socket", filepath.Join(dir, "d.sock"))
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
	if code != 0 || !strings.Contains(errOut, "Usage: tandemd") {
		t.Fatalf("code %d, output %q", code, errOut)
	}
}

func TestMCPHelperArguments(t *testing.T) {
	_, errOut, code := paird(t, "mcp")
	if code != 2 || !strings.Contains(errOut, "--socket and --session are required") {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
	_, errOut, code = paird(t, "mcp", "--socket", "/nonexistent/d.sock", "--session", "x")
	if code != 1 || !strings.Contains(errOut, "cannot reach tandemd") {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
}
