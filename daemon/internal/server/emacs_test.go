package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/zombieleet/tandem/daemon/internal/protocol"
)

func mcpPrompt(t *testing.T, tool string, args map[string]any) string {
	t.Helper()
	b, _ := json.Marshal(args)
	return "script:mcp:" + tool + ":" + string(b)
}

func answerTool(c *testClient, requestID, text string, isError bool) message {
	return c.request("tool/result", map[string]any{"requestId": requestID, "text": text, "isError": isError})
}

func TestOpenFileIsRelayedToEmacs(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	id := createSessionIn(t, c, dir)
	prompt(t, c, id, mcpPrompt(t, "open_file", map[string]any{"path": "a.txt", "line": 3}))
	p := c.nextNotification("tool/call")
	args, _ := p["args"].(map[string]any)
	if p["tool"] != "open_file" || p["sessionId"] != id || p["root"] != dir ||
		args["path"] != filepath.Join(dir, "a.txt") || args["line"] != 3.0 {
		t.Fatalf("tool/call %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "Showing a.txt at line 3 in window 2.", false))
	updates := c.untilIdle(id)
	if got := turnText(updates); got != "open_file result: Showing a.txt at line 3 in window 2." {
		t.Fatalf("text %q", got)
	}
	var titled bool
	for _, u := range updates {
		if u["kind"] == "tool" && u["title"] == "Show a.txt:3" {
			titled = true
		}
		if u["kind"] == "permission" {
			t.Fatalf("window tools must not ask permission: %v", u)
		}
	}
	if !titled {
		t.Fatalf("no tool update titled %q in %v", "Show a.txt:3", updates)
	}
}

func TestWindowToolsChain(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, "script:mcp:list_windows: && close_window:{\"window\":4}")
	p := c.nextNotification("tool/call")
	if p["tool"] != "list_windows" {
		t.Fatalf("first call %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "[1] chat", false))
	p = c.nextNotification("tool/call")
	if p["tool"] != "close_window" || p["args"].(map[string]any)["window"] != 4.0 {
		t.Fatalf("second call %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "Window 4 is the user's.", true))
	if got := turnText(c.untilIdle(id)); got != "list_windows result: [1] chat\nclose_window result: Window 4 is the user's. (error)" {
		t.Fatalf("text %q", got)
	}
}

func TestOpenFileOutsideTheProjectIsRefused(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, mcpPrompt(t, "open_file", map[string]any{"path": "/etc/passwd"}))
	got := turnText(c.untilIdle(id)) // fails on any tool/call notification
	if !strings.Contains(got, "tandem only shows files inside the project") || !strings.HasSuffix(got, "(error)") {
		t.Fatalf("text %q", got)
	}
	prompt(t, c, id, mcpPrompt(t, "open_file", map[string]any{"path": "../x.txt"}))
	if got := turnText(c.untilIdle(id)); !strings.Contains(got, "only shows files inside the project") {
		t.Fatalf("text %q", got)
	}
}

func TestEmacsMustAnswerInTime(t *testing.T) {
	old := EmacsToolTimeout
	EmacsToolTimeout = 300 * time.Millisecond
	t.Cleanup(func() { EmacsToolTimeout = old })
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, mcpPrompt(t, "list_windows", nil))
	p := c.nextNotification("tool/call")
	if got := turnText(c.untilIdle(id)); got != "list_windows result: Emacs did not answer within 300ms. (error)" {
		t.Fatalf("text %q", got)
	}
	// A late answer finds nothing waiting.
	wantCode(t, answerTool(c, p["requestId"].(string), "late", false), protocol.UnknownRequest)
}

func TestOnlyTheAskedEmacsAnswers(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c, other := ready(t, d), ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, mcpPrompt(t, "list_windows", nil))
	p := c.nextNotification("tool/call")
	wantCode(t, answerTool(other, p["requestId"].(string), "not mine", false), protocol.UnknownRequest)
	wantCode(t, other.request("tool/result", map[string]any{"text": "x"}), protocol.InvalidParams)
	wantCode(t, other.request("helper/emacs", map[string]any{"sessionId": id, "tool": "list_windows"}), protocol.MethodNotFound)
	wantOK(t, answerTool(c, p["requestId"].(string), "[1] chat", false))
	wantCode(t, answerTool(c, p["requestId"].(string), "twice", false), protocol.UnknownRequest)
	if got := turnText(c.untilIdle(id)); got != "list_windows result: [1] chat" {
		t.Fatalf("text %q", got)
	}
}

func TestEmacsLeavingEndsTheCall(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	events := filepath.Join(projectDir(t), "events")
	t.Setenv("FAKE_CLAUDE_EVENTS_LOG", events)
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, mcpPrompt(t, "list_windows", nil))
	c.nextNotification("tool/call")
	c.nc.Close()
	waitFor(t, "the call to end", func() bool {
		data, _ := os.ReadFile(events)
		return strings.Contains(string(data), "mcp__emacs__list_windows -> error=true Emacs disconnected before it answered.")
	})
}

func TestReadingToolsAreRelayedWithTheirPaths(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	id := createSessionIn(t, c, dir)
	prompt(t, c, id, "script:mcp:xref:{\"symbol\":\"area\",\"path\":\"a.txt\",\"line\":4} && "+
		"diagnostics: && imenu:{\"path\":\"/etc/passwd\"} && selection:")
	p := c.nextNotification("tool/call")
	args := p["args"].(map[string]any)
	if p["tool"] != "xref" || args["path"] != filepath.Join(dir, "a.txt") || args["symbol"] != "area" || args["line"] != 4.0 {
		t.Fatalf("xref call %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "a.txt:1: def area", false))
	p = c.nextNotification("tool/call")
	if p["tool"] != "diagnostics" || p["args"].(map[string]any)["path"] != nil {
		t.Fatalf("diagnostics without a path: %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "no diagnostics", false))
	// imenu outside the project never reaches Emacs.
	p = c.nextNotification("tool/call")
	if p["tool"] != "selection" {
		t.Fatalf("after the refused imenu, want selection: %v", p)
	}
	wantOK(t, answerTool(c, p["requestId"].(string), "geo.py line 3", false))
	got := turnText(c.untilIdle(id))
	if !strings.Contains(got, "imenu result: tandem only reads files inside the project") {
		t.Fatalf("text %q", got)
	}
	for _, u := range []string{"xref result: a.txt:1: def area", "diagnostics result: no diagnostics", "selection result: geo.py line 3"} {
		if !strings.Contains(got, u) {
			t.Fatalf("text %q lacks %q", got, u)
		}
	}
}
