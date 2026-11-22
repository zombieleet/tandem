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

// nextUpdate reads session updates until match accepts one.
func (c *testClient) nextUpdate(id string, match func(map[string]any) bool) map[string]any {
	c.t.Helper()
	for {
		m := c.note()
		if m.Method != "session/update" {
			c.t.Fatalf("unexpected message %+v", m)
		}
		var u update
		json.Unmarshal(m.Params, &u)
		if u.SessionID == id && match(u.Update) {
			return u.Update
		}
	}
}

// untilIdleAnd reads notifications until session id is idle and one of
// them, a session/update or any other, matched want; the two may come in
// either order. It returns the session's updates and the params of the
// match (the update itself for a session/update).
func (c *testClient) untilIdleAnd(id string, want func(method string, params map[string]any) bool) ([]map[string]any, map[string]any) {
	c.t.Helper()
	var updates []map[string]any
	var found map[string]any
	idle := false
	for !idle || found == nil {
		m := c.note()
		var params map[string]any
		if m.Method == "session/update" {
			var u update
			json.Unmarshal(m.Params, &u)
			if u.SessionID != id {
				continue
			}
			params = u.Update
			updates = append(updates, u.Update)
			idle = idle || (u.Update["kind"] == "status" && u.Update["state"] == "idle")
		} else {
			json.Unmarshal(m.Params, &params)
		}
		if found == nil && want(m.Method, params) {
			found = params
		}
	}
	return updates, found
}

func waitPending(c *testClient, id string) map[string]any {
	return c.nextUpdate(id, func(u map[string]any) bool { return u["kind"] == "permission" && u["state"] == "pending" })
}

func turnText(updates []map[string]any) string {
	var b strings.Builder
	for _, u := range updates {
		if u["kind"] == "text" {
			b.WriteString(u["delta"].(string))
		}
	}
	return b.String()
}

func prompt(t *testing.T, c *testClient, id, text string) {
	t.Helper()
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": text}))
}

func answer(c *testClient, requestID, decision string, always bool, message string) message {
	return c.request("permission/answer", map[string]any{
		"requestId": requestID, "decision": decision, "always": always, "message": message,
	})
}

func TestPermissionAllow(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash:touch x")
	p := waitPending(c, id)
	if p["toolName"] != "Bash" || p["title"] != "Bash touch x" || p["alwaysRule"] != "Bash(touch x)" {
		t.Fatalf("pending %v", p)
	}
	if input := p["input"].(map[string]any); input["command"] != "touch x" {
		t.Fatalf("input %v", input)
	}
	wantOK(t, answer(c, p["requestId"].(string), "allow", false, ""))
	updates := c.untilIdle(id)
	if got := turnText(updates); got != "allowed: touch x" {
		t.Fatalf("text %q", got)
	}
	var answered bool
	for _, u := range updates {
		if u["kind"] == "permission" && u["state"] == "answered" && u["decision"] == "allow" {
			answered = true
		}
	}
	if !answered {
		t.Fatal("no answered update")
	}
}

func TestPermissionDenyWithAReason(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash:rm -rf build")
	p := waitPending(c, id)
	wantOK(t, answer(c, p["requestId"].(string), "deny", false, "use make clean instead"))
	updates := c.untilIdle(id)
	if got := turnText(updates); got != "denied: use make clean instead" {
		t.Fatalf("text %q", got)
	}
	for _, u := range updates {
		if u["kind"] == "result" {
			if denied := u["permissionDenials"].([]any); len(denied) != 1 || denied[0] != "Bash" {
				t.Fatalf("denials %v", denied)
			}
		}
	}
}

func TestPermissionDenyWithoutAReason(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash:touch x")
	wantOK(t, answer(c, waitPending(c, id)["requestId"].(string), "deny", false, ""))
	if got := turnText(c.untilIdle(id)); got != "denied: The user denied this." {
		t.Fatalf("text %q", got)
	}
}

func TestPermissionAlwaysAllowAddsARule(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash2:touch x")
	wantOK(t, answer(c, waitPending(c, id)["requestId"].(string), "allow", true, ""))
	updates := c.untilIdle(id)
	want := "allowed: touch x (rule: Bash(touch x) in localSettings)\nallowed by rule: touch x"
	if got := turnText(updates); got != want {
		t.Fatalf("text\n got %q\nwant %q", got, want)
	}
	for _, u := range updates {
		if u["kind"] == "permission" && u["state"] == "pending" {
			t.Fatal("the second, identical command must not ask again")
		}
	}
}

func TestPermissionWebFetchRuleIsTheDomain(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:webfetch:https://docs.example.com/a/b?q=1")
	p := waitPending(c, id)
	if p["alwaysRule"] != "WebFetch(domain:docs.example.com)" || p["title"] != "WebFetch https://docs.example.com/a/b?q=1" {
		t.Fatalf("pending %v", p)
	}
	wantOK(t, answer(c, p["requestId"].(string), "allow", true, ""))
	if got := turnText(c.untilIdle(id)); !strings.Contains(got, "rule: WebFetch(domain:docs.example.com) in localSettings") {
		t.Fatalf("text %q", got)
	}
}

func TestCancelWithdrawsAPendingPermission(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash:touch x")
	requestID := waitPending(c, id)["requestId"].(string)
	m := c.request("session/cancel", map[string]string{"sessionId": id})
	if string(m.Result) != `{"cancelled":true}` {
		t.Fatalf("cancel %s", m.Result)
	}
	// The withdrawal and the end of the turn come in either order.
	updates, w := c.untilIdleAnd(id, func(method string, u map[string]any) bool {
		return method == "session/update" && u["kind"] == "permission"
	})
	if w["state"] != "withdrawn" || w["requestId"] != requestID || w["reason"] != "The user stopped the turn." {
		t.Fatalf("got %v, want the request withdrawn", w)
	}
	var cancelled bool
	for _, u := range updates {
		if u["kind"] == "result" && u["cancelled"] == true {
			cancelled = true
		}
	}
	if !cancelled {
		t.Fatal("the turn did not end as cancelled")
	}
	wantCode(t, answer(c, requestID, "allow", false, ""), protocol.UnknownRequest)
}

func TestPermissionAnswerErrors(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	wantCode(t, answer(c, "perm-nope", "allow", false, ""), protocol.UnknownRequest)
	wantCode(t, answer(c, "perm-nope", "maybe", false, ""), protocol.InvalidParams)
	wantCode(t, c.request("permission/answer", map[string]string{}), protocol.InvalidParams)
	// Emacs may not pose as the helper.
	wantCode(t, c.request("helper/permission", map[string]string{"sessionId": "x", "toolName": "Bash"}), protocol.MethodNotFound)
}

func TestNobodyToAskMeansDenied(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	events := filepath.Join(projectDir(t), "events")
	t.Setenv("FAKE_CLAUDE_EVENTS_LOG", events)
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:sleepbash:300:touch x")
	c.nc.Close() // Emacs goes away before Claude asks
	deadline := time.Now().Add(5 * time.Second)
	for {
		data, _ := os.ReadFile(events)
		if strings.Contains(string(data), "Bash touch x -> deny No Emacs is connected") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("events log: %q", data)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestTheHelperIsNotAClient(t *testing.T) {
	d := startDaemon(t, 150*time.Millisecond, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	prompt(t, c, id, "script:bash:touch x")
	p := waitPending(c, id) // the helper is connected now
	var s protocol.StatusResult
	json.Unmarshal(c.request("daemon/status", nil).Result, &s)
	if s.Clients != 1 {
		t.Fatalf("clients %d; the MCP helper must not count", s.Clients)
	}
	wantOK(t, answer(c, p["requestId"].(string), "allow", false, ""))
	c.untilIdle(id)
	// claude and its helper stay up between turns; they must not keep the
	// daemon alive once Emacs has gone.
	c.nc.Close()
	select {
	case <-d.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("an idle claude with its helper kept the daemon running")
	}
}

func TestPlanModeAndAnEditedPlan(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSession(t, c, fakeClaude)
	wantCode(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "x", "permissionMode": "yolo"}),
		protocol.InvalidParams)
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "document area", "permissionMode": "plan"}))
	p := waitPending(c, id)
	if p["toolName"] != "ExitPlanMode" || len(p["input"].(map[string]any)) != 0 {
		t.Fatalf("pending %v", p)
	}
	// The user's version of the plan goes to Claude.
	wantOK(t, c.request("permission/answer", map[string]any{
		"requestId": p["requestId"], "decision": "allow",
		"updatedInput": map[string]any{"plan": "1. Add a docstring\n2. Add type hints"},
	}))
	if got := turnText(c.untilIdle(id)); got != "\nFollowing the plan:\n1. Add a docstring\n2. Add type hints" {
		t.Fatalf("text %q", got)
	}
	// A plain prompt afterwards is in default mode again.
	prompt(t, c, id, "hello")
	if got := turnText(c.untilIdle(id)); got != "You said: hello" {
		t.Fatalf("text %q", got)
	}
	// Rejected, with a note.
	wantOK(t, c.request("session/prompt", map[string]string{"sessionId": id, "text": "again", "permissionMode": "plan"}))
	p = waitPending(c, id)
	wantOK(t, answer(c, p["requestId"].(string), "deny", false, "too big"))
	if got := turnText(c.untilIdle(id)); got != "\nThe plan was rejected: too big" {
		t.Fatalf("text %q", got)
	}
}
