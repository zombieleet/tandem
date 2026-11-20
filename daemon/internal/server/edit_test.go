package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/victory/claude-pair/daemon/internal/protocol"
)

func createSessionIn(t *testing.T, c *testClient, cwd string) string {
	t.Helper()
	m := c.request("session/new", map[string]string{"cwd": cwd, "claudePath": fakeClaude})
	wantOK(t, m)
	var r struct{ SessionID string }
	json.Unmarshal(m.Result, &r)
	return r.SessionID
}

// nextNotification reads until a notification with method arrives.
func (c *testClient) nextNotification(method string) map[string]any {
	c.t.Helper()
	for {
		m := c.note()
		if m.Method == method {
			var p map[string]any
			json.Unmarshal(m.Params, &p)
			return p
		}
	}
}

func editPrompt(t *testing.T, spec map[string]any) string {
	t.Helper()
	b, _ := json.Marshal(spec)
	return "script:edit:" + string(b)
}

func answerEdit(c *testClient, requestID string, a map[string]any) message {
	a["requestId"] = requestID
	return c.request("edit/answer", a)
}

func project(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("one x two\n"), 0o600)
	return dir
}

func TestEditIsProposedAndApplied(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	id := createSessionIn(t, c, dir)
	prompt(t, c, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "y"}))
	p := c.nextNotification("edit/propose")
	if p["kind"] != "edit" || p["filePath"] != filepath.Join(dir, "a.txt") || p["oldString"] != "x" ||
		p["newString"] != "y" || p["replaceAll"] != false || p["sessionId"] != id {
		t.Fatalf("proposal %v", p)
	}
	wantOK(t, answerEdit(c, p["requestId"].(string), map[string]any{"outcome": "applied", "saved": true}))
	updates := c.untilIdle(id)
	if got := turnText(updates); got != "edit result: The user applied the edit to a.txt in Emacs, and it is saved." {
		t.Fatalf("text %q", got)
	}
	var pending, applied bool
	for _, u := range updates {
		if u["kind"] == "edit" && u["state"] == "pending" && u["relPath"] == "a.txt" && u["title"] == "Edit a.txt" {
			pending = true
		}
		if u["kind"] == "edit" && u["state"] == "applied" {
			applied = true
		}
		if u["kind"] == "permission" {
			t.Fatalf("the edit tools must not ask a separate permission question: %v", u)
		}
	}
	if !pending || !applied {
		t.Fatalf("pending %v, applied %v", pending, applied)
	}
}

func TestEditOutcomesAsClaudeReadsThem(t *testing.T) {
	cases := []struct {
		answer map[string]any
		want   string
	}{
		{map[string]any{"outcome": "applied", "saved": false},
			"edit result: The user applied the edit to a.txt in Emacs. It is not saved yet, because that buffer has unsaved changes"},
		{map[string]any{"outcome": "rejected", "message": "keep the old name"},
			"edit result: The user rejected this edit to a.txt. Their note: keep the old name Do not send the same change again."},
		{map[string]any{"outcome": "rejected"},
			"edit result: The user rejected this edit to a.txt. Do not send the same change again."},
		{map[string]any{"outcome": "error", "message": "String to replace not found in file.\nString: x"},
			"edit result: String to replace not found in file.\nString: x"},
	}
	for _, tc := range cases {
		d := startDaemon(t, 0, "cpd-")
		c := ready(t, d)
		id := createSessionIn(t, c, project(t))
		prompt(t, c, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "y"}))
		p := c.nextNotification("edit/propose")
		wantOK(t, answerEdit(c, p["requestId"].(string), tc.answer))
		if got := turnText(c.untilIdle(id)); !strings.HasPrefix(got, tc.want) {
			t.Errorf("answer %v:\n got %q\nwant %q…", tc.answer, got, tc.want)
		}
		d.Stop("next case")
	}
}

func TestWriteCreatesAFile(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	id := createSessionIn(t, c, dir)
	b, _ := json.Marshal(map[string]any{"file": "new/b.txt", "content": "hello\n"})
	prompt(t, c, id, "script:write:"+string(b))
	p := c.nextNotification("edit/propose")
	if p["kind"] != "write" || p["filePath"] != filepath.Join(dir, "new", "b.txt") || p["content"] != "hello\n" {
		t.Fatalf("proposal %v", p)
	}
	wantOK(t, answerEdit(c, p["requestId"].(string), map[string]any{"outcome": "applied", "saved": true, "created": true}))
	if got := turnText(c.untilIdle(id)); got != "edit result: The user accepted the new file new/b.txt; it is created and saved." {
		t.Fatalf("text %q", got)
	}
}

func TestEditsOutsideTheProjectAreRefused(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(dir, "escape"))
	id := createSessionIn(t, c, dir)
	for _, file := range []string{"/etc/hosts", filepath.Join(dir, "..", "x.txt"), filepath.Join(dir, "escape", "x.txt")} {
		prompt(t, c, id, editPrompt(t, map[string]any{"file": file, "old": "a", "new": "b"}))
		updates := c.untilIdle(id)
		if got := turnText(updates); !strings.Contains(got, "claude-pair only edits files inside the project") {
			t.Fatalf("%s: text %q", file, got)
		}
		for _, u := range updates {
			if u["kind"] == "edit" {
				t.Fatalf("%s must not be proposed: %v", file, u)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(outside, "x.txt")); err == nil {
		t.Fatal("a file appeared outside the project")
	}
}

func TestEditWithIdenticalStringsIsRefused(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "x"}))
	if got := turnText(c.untilIdle(id)); got != "edit result: No changes to make: old_string and new_string are exactly the same." {
		t.Fatalf("text %q", got)
	}
}

func TestCancelWithdrawsAnEdit(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	id := createSessionIn(t, c, project(t))
	prompt(t, c, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "y"}))
	requestID := c.nextNotification("edit/propose")["requestId"].(string)
	c.request("session/cancel", map[string]string{"sessionId": id})
	w := c.nextNotification("edit/withdraw")
	if w["requestId"] != requestID || w["reason"] != "The user stopped the turn." {
		t.Fatalf("withdraw %v", w)
	}
	c.untilIdle(id)
	wantCode(t, answerEdit(c, requestID, map[string]any{"outcome": "applied"}), protocol.UnknownRequest)
}

func TestOnlyTheReviewingEmacsMayAnswer(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	a, b := ready(t, d), ready(t, d)
	id := createSessionIn(t, a, project(t))
	prompt(t, a, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "y"}))
	requestID := a.nextNotification("edit/propose")["requestId"].(string)
	m := answerEdit(b, requestID, map[string]any{"outcome": "applied"})
	wantCode(t, m, protocol.UnknownRequest)
	if !strings.Contains(m.Error.Message, "another Emacs") {
		t.Fatalf("message %q", m.Error.Message)
	}
	wantCode(t, answerEdit(a, requestID, map[string]any{"outcome": "maybe"}), protocol.InvalidParams)
	wantOK(t, answerEdit(a, requestID, map[string]any{"outcome": "rejected"}))
	a.untilIdle(id)
}

func TestInsideProject(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "sub"), 0o700)
	ok := []string{filepath.Join(dir, "a.go"), filepath.Join(dir, "sub", "b.go"), filepath.Join(dir, "new", "dir", "c.go"),
		filepath.Join(dir, "sub", "..", "d.go")}
	for _, p := range ok {
		if _, err := insideProject(dir, p, "edits"); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
	bad := []string{"", "relative.go", "/etc/passwd", filepath.Join(dir, "..", "x.go"), dir + "-other/x.go"}
	for _, p := range bad {
		if _, err := insideProject(dir, p, "edits"); err == nil {
			t.Errorf("%s was accepted", p)
		}
	}
}

func TestPartialEditTellsClaudeEachHunk(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	dir := project(t)
	id := createSessionIn(t, c, dir)
	prompt(t, c, id, editPrompt(t, map[string]any{"file": "a.txt", "old": "x", "new": "y"}))
	p := c.nextNotification("edit/propose")
	wantCode(t, answerEdit(c, p["requestId"].(string), map[string]any{"outcome": "partial"}), protocol.InvalidParams)
	wantOK(t, answerEdit(c, p["requestId"].(string), map[string]any{
		"outcome": "partial", "saved": true,
		"hunks": []map[string]any{
			{"index": 1, "line": 3, "oldLines": 2, "newLines": 3, "decision": "applied", "saved": true},
			{"index": 2, "line": 20, "oldLines": 1, "newLines": 1, "decision": "rejected", "note": "keep the old name"},
			{"index": 3, "line": 30, "oldLines": 1, "newLines": 0, "decision": "error",
				"note": "The text to replace changed in Emacs while the user was reviewing the edit.  Read the file again."},
		}}))
	updates := c.untilIdle(id)
	want := "edit result: The user reviewed your edit to a.txt hunk by hunk and applied 1 of its 3 hunks:\n" +
		"- Hunk 1 (2 lines at line 3, becoming 3 lines): applied.\n" +
		"- Hunk 2 (1 line at line 20): rejected; those lines are unchanged. Their note: keep the old name\n" +
		"- Hunk 3 (1 line at line 30, becoming 0 lines): not applied: The text to replace changed in Emacs while the user was reviewing the edit.  Read the file again.\n" +
		"The applied hunks are saved. The file now differs from your new_string, so read it again before you edit it further, and do not send rejected hunks again unchanged."
	if got := turnText(updates); got != want {
		t.Fatalf("text:\n%s\nwant:\n%s", got, want)
	}
	var partial map[string]any
	for _, u := range updates {
		if u["kind"] == "edit" && u["state"] == "partial" {
			partial = u
		}
	}
	if hunks, _ := partial["hunks"].([]any); len(hunks) != 3 {
		t.Fatalf("followers get the hunks: %v", partial)
	}
}
