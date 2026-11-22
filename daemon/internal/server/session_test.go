package server

import (
	"encoding/json"
	"errors"
	"github.com/victory/tandem/daemon/internal/testutil"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/victory/tandem/daemon/internal/protocol"
	"github.com/victory/tandem/daemon/internal/session"
)

var fakeClaude, helperBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cpd-fake-")
	if err != nil {
		panic(err)
	}
	if fakeClaude, err = testutil.Binary(dir, "fakeclaude", "../testutil/fakeclaude"); err != nil {
		panic(err)
	}
	if helperBinary, err = testutil.Binary(dir, "tandemd", "../../cmd/tandemd"); err != nil {
		panic(err)
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
	m := c.request("session/new", map[string]string{"cwd": projectDir(t), "claudePath": claude})
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
	dir := projectDir(t)
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

func TestSessionEnvironment(t *testing.T) {
	t.Setenv("CP_TEST_INHERITED", "daemon")
	t.Setenv("CP_TEST_REMOVED", "daemon")
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	m := c.request("session/new", map[string]any{"cwd": projectDir(t), "claudePath": fakeClaude,
		"env": map[string]any{"CP_TEST_SET": "from emacs", "CP_TEST_REMOVED": nil}})
	wantOK(t, m)
	var r struct{ SessionID string }
	json.Unmarshal(m.Result, &r)
	prompt(t, c, r.SessionID, "script:env:CP_TEST_SET,CP_TEST_REMOVED,CP_TEST_INHERITED")
	if got := turnText(c.untilIdle(r.SessionID)); got != "CP_TEST_SET=from emacs CP_TEST_REMOVED unset CP_TEST_INHERITED=daemon" {
		t.Fatalf("text %q", got)
	}
	wantCode(t, c.request("session/new", map[string]any{"cwd": projectDir(t), "claudePath": fakeClaude,
		"env": map[string]any{"A=B": "x"}}), protocol.InvalidParams)
}

func TestTheLogNeverHoldsEnvironmentValues(t *testing.T) {
	var log strings.Builder
	var mu sync.Mutex
	d := startDaemonWithLog(t, func(p []byte) { mu.Lock(); log.Write(p); mu.Unlock() })
	c := ready(t, d)
	m := c.request("session/new", map[string]any{"cwd": projectDir(t), "claudePath": fakeClaude,
		"env": map[string]any{"ANTHROPIC_API_KEY": "sk-secret-value"}})
	wantOK(t, m)
	var r struct{ SessionID string }
	json.Unmarshal(m.Result, &r)
	prompt(t, c, r.SessionID, "script:hello")
	c.untilIdle(r.SessionID)
	mu.Lock()
	defer mu.Unlock()
	if strings.Contains(log.String(), "sk-secret-value") {
		t.Fatal("the daemon log holds an environment value")
	}
}

type writeFunc func([]byte)

func (f writeFunc) Write(p []byte) (int, error) { f(p); return len(p), nil }

// startDaemonWithLog starts a daemon whose debug log goes to write.
func startDaemonWithLog(t *testing.T, write func([]byte)) *Daemon {
	t.Helper()
	name := "d.sock"
	if overTCP {
		name = "d.json"
	}
	d := New(Options{
		SocketPath: filepath.Join(privateDir(t, "cpd-"), name),
		Version:    "9.9.9-test",
		HelperPath: helperBinary,
		Log:        slog.New(slog.NewTextHandler(writeFunc(write), &slog.HandlerOptions{Level: slog.LevelDebug})),
		TCP:        overTCP,
	})
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Stop("test cleanup") })
	testDaemonsMu.Lock()
	testDaemons[t] = append(testDaemons[t], d)
	testDaemonsMu.Unlock()
	return d
}

func TestListAndResumeAConversation(t *testing.T) {
	config := projectDir(t)
	t.Setenv("CLAUDE_CONFIG_DIR", config)
	argsLog := filepath.Join(projectDir(t), "args")
	t.Setenv("FAKE_CLAUDE_ARGS_LOG", argsLog)
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	cwd := projectDir(t)
	m := c.request("session/new", map[string]string{"cwd": cwd, "claudePath": fakeClaude})
	wantOK(t, m)
	var r struct{ SessionID string }
	json.Unmarshal(m.Result, &r)
	prompt(t, c, r.SessionID, "script:hello")
	c.untilIdle(r.SessionID)

	// Listed, and marked as running here.
	m = c.request("session/list", map[string]string{"cwd": cwd})
	wantOK(t, m)
	var list struct {
		Sessions []struct {
			SessionID, Title string
			Prompts          int
			Running, Busy    bool
		}
	}
	json.Unmarshal(m.Result, &list)
	if len(list.Sessions) != 1 || list.Sessions[0].SessionID != r.SessionID || list.Sessions[0].Title != "script:hello" ||
		list.Sessions[0].Prompts != 1 || !list.Sessions[0].Running {
		t.Fatalf("list %+v", list)
	}

	// Another Emacs reattaches to the running session and gets its updates.
	c2 := ready(t, d)
	m = c2.request("session/resume", map[string]string{"sessionId": r.SessionID, "cwd": cwd, "claudePath": fakeClaude})
	wantOK(t, m)
	var res struct {
		Running bool
		History []struct{ Kind, Text, Title string }
	}
	json.Unmarshal(m.Result, &res)
	if !res.Running || len(res.History) != 2 || res.History[0].Text != "script:hello" || res.History[1].Text != "Hello wörld 🌍" {
		t.Fatalf("resume %+v", res)
	}

	// Closed, then resumed: claude starts again with --resume.
	wantOK(t, c.request("session/close", map[string]string{"sessionId": r.SessionID}))
	m = c2.request("session/resume", map[string]string{"sessionId": r.SessionID, "cwd": cwd, "claudePath": fakeClaude})
	wantOK(t, m)
	json.Unmarshal(m.Result, &res)
	if res.Running || len(res.History) != 2 {
		t.Fatalf("resume after close %+v", res)
	}
	prompt(t, c2, r.SessionID, "again")
	if got := turnText(c2.untilIdle(r.SessionID)); got != "You said: again" {
		t.Fatalf("text %q", got)
	}
	logged, _ := os.ReadFile(argsLog)
	lines := strings.Split(strings.TrimSpace(string(logged)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], "--session-id "+r.SessionID) || !strings.Contains(lines[1], "--resume "+r.SessionID) {
		t.Fatalf("starts:\n%s", logged)
	}

	// Unknown, malformed or outside the project.
	wantCode(t, c2.request("session/resume", map[string]string{"sessionId": "aaaaaaaa-2222-4333-8444-555555555555",
		"cwd": cwd, "claudePath": fakeClaude}), protocol.UnknownSession)
	wantCode(t, c2.request("session/resume", map[string]string{"sessionId": "../x", "cwd": cwd,
		"claudePath": fakeClaude}), protocol.InvalidParams)
	wantCode(t, c2.request("session/resume", map[string]string{"sessionId": r.SessionID, "cwd": projectDir(t),
		"claudePath": fakeClaude}), protocol.UnknownSession)
	wantCode(t, c2.request("session/list", map[string]string{"cwd": "relative"}), protocol.InvalidParams)
}

func TestSlashCommands(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	m := c.request("session/commands", map[string]string{"sessionId": id})
	wantOK(t, m)
	var r struct {
		Commands []struct {
			Name, Description, ArgumentHint string
			Aliases                         []string
			Builtin                         bool
		}
	}
	json.Unmarshal(m.Result, &r)
	var names []string
	for _, cmd := range r.Commands {
		names = append(names, cmd.Name)
	}
	// The terminal-only /doctor is left out.
	if strings.Join(names, ",") != "compact,clear,greet" || r.Commands[2].ArgumentHint != "NAME" ||
		!r.Commands[0].Builtin || r.Commands[1].Aliases[0] != "reset" {
		t.Fatalf("commands %+v", r.Commands)
	}
	wantCode(t, c.request("session/commands", map[string]string{"sessionId": "nope"}), protocol.UnknownSession)

	// What /compact prints shows as text; the status says it compacts.
	prompt(t, c, id, "/compact")
	updates := c.untilIdle(id)
	if got := turnText(updates); got != "Compacted\n" {
		t.Fatalf("text %q", got)
	}
	compacting := false
	for _, u := range updates {
		if u["kind"] == "status" && u["state"] == "compacting" {
			compacting = true
		}
	}
	if !compacting {
		t.Fatalf("no compacting status in %v", updates)
	}
	prompt(t, c, id, "/greet Bob")
	if got := turnText(c.untilIdle(id)); got != "Ran /greet with Bob" {
		t.Fatalf("text %q", got)
	}
}

func TestRewindToAnEarlierTurn(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", projectDir(t))
	argsLog := filepath.Join(projectDir(t), "args")
	t.Setenv("FAKE_CLAUDE_ARGS_LOG", argsLog)
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	for _, text := range []string{"one", "two"} {
		prompt(t, c, id, text)
		c.untilIdle(id)
	}
	type entry struct{ Kind, Text, Before, BeforeTime string }
	history := func() []entry {
		m := c.request("session/history", map[string]string{"sessionId": id})
		wantOK(t, m)
		var r struct{ History []entry }
		json.Unmarshal(m.Result, &r)
		return r.History
	}
	h := history()
	if len(h) != 4 || h[0].Text != "one" || h[0].Before != "" || h[2].Text != "two" || h[2].Before == "" || h[2].BeforeTime == "" {
		t.Fatalf("history %+v", h)
	}
	before := h[2].Before
	wantCode(t, c.request("session/rewind", map[string]string{"sessionId": id, "before": "nope"}), protocol.InvalidParams)
	wantOK(t, c.request("session/rewind", map[string]string{"sessionId": id, "before": before}))

	// "two" is forgotten; the next start goes back, the one after follows.
	prompt(t, c, id, "three")
	c.untilIdle(id)
	h = history()
	var texts []string
	for _, e := range h {
		if e.Kind == "user" {
			texts = append(texts, e.Text)
		}
	}
	if strings.Join(texts, ",") != "one,three" {
		t.Fatalf("after rewind %+v", h)
	}
	wantOK(t, c.request("session/cancel", map[string]string{"sessionId": id}))
	logged, _ := os.ReadFile(argsLog)
	lines := strings.Split(strings.TrimSpace(string(logged)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[1], "--resume "+id+" ") || !strings.HasSuffix(lines[1], "--resume-session-at "+before) {
		t.Fatalf("starts:\n%s", logged)
	}
}

func TestAllSessions(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	a := createSession(t, c, fakeClaude)
	b := createSession(t, c, fakeClaude)
	prompt(t, c, a, "script:hello")
	c.untilIdle(a)
	m := c.request("session/all", nil)
	wantOK(t, m)
	var r struct {
		Sessions []struct {
			SessionID, Cwd string
			Busy           bool
			CostUSD        float64 `json:"costUsd"`
			Followers      int
		}
	}
	json.Unmarshal(m.Result, &r)
	if len(r.Sessions) != 2 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
	for _, s := range r.Sessions {
		if s.Cwd == "" || s.Busy || s.Followers != 1 {
			t.Fatalf("session %+v", s)
		}
		if s.SessionID == a && s.CostUSD == 0 {
			t.Fatalf("no cost for the session that ran: %+v", s)
		}
		if s.SessionID != a && s.SessionID != b {
			t.Fatalf("unknown session %+v", s)
		}
	}
	// A second Emacs follows none of them.
	c2 := ready(t, d)
	wantOK(t, c2.request("session/all", nil))
}

func TestUnknownFieldsAreIgnored(t *testing.T) {
	// A newer client may send params this daemon does not know (see the
	// protocol's Versions section).
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.request("initialize", map[string]any{"protocolVersion": protocol.Version, "token": c.token,
		"clientInfo": map[string]string{"name": "test"}, "fromTheFuture": map[string]any{"x": 1}}))
	m := c.request("session/new", map[string]any{"cwd": projectDir(t), "claudePath": fakeClaude,
		"fromTheFuture": true})
	wantOK(t, m)
	var r struct{ SessionID string }
	json.Unmarshal(m.Result, &r)
	wantOK(t, c.request("session/prompt", map[string]any{"sessionId": r.SessionID, "text": "hi", "fromTheFuture": 1}))
	if got := turnText(c.untilIdle(r.SessionID)); got != "You said: hi" {
		t.Fatalf("text %q", got)
	}
	wantCode(t, c.request("session/fromTheFuture", nil), protocol.MethodNotFound)
}
