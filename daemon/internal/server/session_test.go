package server

import (
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

	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/session"
)

var fakeClaude, helperBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cpd-fake-")
	if err != nil {
		panic(err)
	}
	fakeClaude = filepath.Join(dir, "fakeclaude")
	helperBinary = filepath.Join(dir, "claude-paird")
	for out, pkg := range map[string]string{fakeClaude: "../testutil/fakeclaude", helperBinary: "../../cmd/claude-paird"} {
		if msg, err := exec.Command("go", "build", "-o", out, pkg).CombinedOutput(); err != nil {
			panic(fmt.Sprintf("building %s: %v\n%s", pkg, err, msg))
		}
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type update struct {
	SessionID string         `json:"sessionId"`
	Update    map[string]any `json:"update"`
}

// untilIdle reads session/update notifications until the session is idle.
func (c *testClient) untilIdle(id string) []map[string]any {
	c.t.Helper()
	var updates []map[string]any
	for {
		m := c.note()
		if m.Method != "session/update" {
			c.t.Fatalf("unexpected message %+v", m)
		}
		var u update
		json.Unmarshal(m.Params, &u)
		if u.SessionID != id {
			c.t.Fatalf("update for %q, want %q", u.SessionID, id)
		}
		updates = append(updates, u.Update)
		if u.Update["kind"] == "status" && u.Update["state"] == "idle" {
			return updates
		}
	}
}

func createSession(t *testing.T, c *testClient, claude string) string {
	t.Helper()
	m := c.request("session/new", map[string]string{"cwd": t.TempDir(), "claudePath": claude})
	wantOK(t, m)
	var r struct{ SessionID, ClaudeVersion string }
	json.Unmarshal(m.Result, &r)
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(r.SessionID) {
		t.Fatalf("session id %q is not a UUID", r.SessionID)
	}
	if r.ClaudeVersion != "2.1.327" {
		t.Fatalf("claudeVersion %q", r.ClaudeVersion)
	}
	return r.SessionID
}

func ready(t *testing.T, d *Daemon) *testClient {
	t.Helper()
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	return c
}

func TestSessionLifecycle(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "script:hello"}))
	var text strings.Builder
	var kinds []string
	for _, u := range c.untilIdle(id) {
		kinds = append(kinds, u["kind"].(string))
		if u["kind"] == "text" {
			text.WriteString(u["delta"].(string))
		}
	}
	if text.String() != "Hello wörld 🌍" {
		t.Fatalf("text %q (kinds %v)", text.String(), kinds)
	}
	var s protocol.StatusResult
	json.Unmarshal(c.request("daemon/status", nil).Result, &s)
	if s.Sessions != 1 {
		t.Fatalf("sessions %d", s.Sessions)
	}
	wantOK(t, c.request("session/close", map[string]string{"sessionId": id}))
	json.Unmarshal(c.request("daemon/status", nil).Result, &s)
	if s.Sessions != 0 {
		t.Fatalf("sessions %d after close", s.Sessions)
	}
	wantCode(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "hi"}), protocol.UnknownSession)
}

func TestSessionNewChecksItsParams(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	os.WriteFile(file, nil, 0o600)
	for _, p := range []map[string]string{
		{"cwd": "relative/dir", "claudePath": fakeClaude},
		{"cwd": filepath.Join(dir, "missing"), "claudePath": fakeClaude},
		{"cwd": file, "claudePath": fakeClaude},
		{"claudePath": fakeClaude},
	} {
		wantCode(t, c.request("session/new", p), protocol.InvalidParams)
	}
	m := c.request("session/new", map[string]string{"cwd": dir, "claudePath": "/nonexistent/claude"})
	wantCode(t, m, protocol.ClaudeUnavailable)
	if !strings.Contains(m.Error.Message, "/nonexistent/claude") {
		t.Fatalf("message %q should name the path", m.Error.Message)
	}
}

func TestSessionErrors(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	wantCode(t, c.request("session/prompt", map[string]string{"sessionId": "nope", "text": "hi"}), protocol.UnknownSession)
	wantCode(t, c.request("session/prompt", map[string]string{"sessionId": id}), protocol.InvalidParams)
	wantCode(t, c.request("session/cancel", map[string]string{}), protocol.InvalidParams)

	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "script:slow"}))
	wantCode(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "again"}), protocol.SessionBusy)
	m := c.request("session/cancel", map[string]string{"sessionId": id})
	if string(m.Result) != `{"cancelled":true}` {
		t.Fatalf("cancel result %s", m.Result)
	}
	var cancelled bool
	for _, u := range c.untilIdle(id) {
		if u["kind"] == "result" && u["cancelled"] == true {
			cancelled = true
		}
	}
	if !cancelled {
		t.Fatal("no cancelled result")
	}
	m = c.request("session/cancel", map[string]string{"sessionId": id})
	if string(m.Result) != `{"cancelled":false}` {
		t.Fatalf("second cancel result %s", m.Result)
	}
}

func TestUpdatesGoOnlyToFollowers(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	a, b := ready(t, d), ready(t, d)
	id := createSession(t, a, fakeClaude)
	wantOK(t, a.request("session/prompt", map[string]string{"sessionId": id, "text": "script:hello"}))
	a.untilIdle(id)
	b.nc.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if _, err := b.reader.Read(); err == nil {
		t.Fatal("a client that did not join the session got its updates")
	} else if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
		t.Fatalf("read: %v", err)
	}

	// Prompting a session makes the client a follower.
	wantOK(t, b.request("session/prompt", map[string]string{"sessionId": id, "text": "script:hello"}))
	b.untilIdle(id)
	a.untilIdle(id)
}

func TestIdleTimeoutWaitsForTheRunningTurn(t *testing.T) {
	d := startDaemon(t, 150*time.Millisecond, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "script:slow:40"}))
	started := time.Now()
	c.nc.Close()
	select {
	case <-d.Done():
		t.Fatalf("the daemon stopped %s into a running turn", time.Since(started))
	case <-time.After(500 * time.Millisecond):
	}
	select {
	case <-d.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the daemon did not stop after the turn ended")
	}
	if elapsed := time.Since(started); elapsed < 800*time.Millisecond {
		t.Fatalf("stopped after %s, before the 800 ms turn could finish", elapsed)
	}
	if d.StopReason() != "idle" {
		t.Fatalf("reason %q", d.StopReason())
	}
}

func TestStopEndsRunningSessions(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "script:slow"}))
	d.mu.Lock()
	s := d.sessions[id].s
	d.mu.Unlock()
	d.Stop("test")
	if s.Busy() {
		t.Fatal("the session still runs after Stop")
	}
	if err := s.Prompt("hi"); !errors.Is(err, errClosedForTest()) {
		t.Fatalf("prompt after Stop: %v", err)
	}
}

func errClosedForTest() error { return session.ErrClosed }
