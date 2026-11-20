package server

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/rpc"
	"github.com/victory/claude-pair/daemon/internal/session"
)

// An edit travels like this: Claude calls edit_file or write_file on the
// MCP helper; the helper sends helper/edit here; the daemon checks the path
// and sends edit/propose to the Emacs that answers for the session; Emacs
// checks the change against the live buffer, shows it, and answers with
// edit/answer once the user decides; the daemon tells Claude the outcome as
// the tool's result. Followers see each step as a session update of kind
// "edit". A cancelled turn, a closed session or a departed helper withdraws
// the proposal (edit/withdraw).

type editAnswer struct {
	Outcome string `json:"outcome"` // applied, rejected or error
	Message string `json:"message"`
	Saved   bool   `json:"saved"`
	Created bool   `json:"created"`
}

type pendingEdit struct {
	id        string
	sessionID string
	asker     *client
	answer    chan editAnswer
	withdraw  chan string
}

type toolResult struct {
	Text    string `json:"text"`
	IsError bool   `json:"isError"`
}

func (d *Daemon) proposeEdit(ctx context.Context, c *client, params json.RawMessage) (any, error) {
	if !c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "helper/edit is for the MCP helper only")
	}
	var p struct {
		SessionID  string `json:"sessionId"`
		Kind       string `json:"kind"`
		FilePath   string `json:"filePath"`
		OldString  string `json:"oldString"`
		NewString  string `json:"newString"`
		ReplaceAll bool   `json:"replaceAll"`
		Content    string `json:"content"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.SessionID == "" ||
		(p.Kind != "edit" && p.Kind != "write") {
		return nil, rpc.Errorf(protocol.InvalidParams, `helper/edit needs a sessionId and a kind of "edit" or "write"`)
	}
	failed := func(text string) (any, error) { return toolResult{Text: text, IsError: true}, nil }

	d.mu.Lock()
	e := d.sessions[p.SessionID]
	asker := d.askerLocked(e)
	d.mu.Unlock()
	if e == nil {
		return failed("The edit was not made: claude-pair has no such session.")
	}
	path, err := insideProject(e.s.Cwd(), p.FilePath)
	if err != nil {
		return failed("The edit was not made: " + err.Error())
	}
	if p.Kind == "edit" && p.OldString == p.NewString {
		return failed("No changes to make: old_string and new_string are exactly the same.")
	}
	if asker == nil {
		return failed("The edit was not made: no Emacs is connected to review it.")
	}

	req := &pendingEdit{
		id: newRequestID("edit-"), sessionID: p.SessionID, asker: asker,
		answer: make(chan editAnswer, 1), withdraw: make(chan string, 1),
	}
	d.mu.Lock()
	d.edits[req.id] = req
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.edits, req.id)
		d.mu.Unlock()
	}()

	rel := relativeTo(e.s.Cwd(), path)
	toolName := "mcp__emacs__edit_file"
	if p.Kind == "write" {
		toolName = "mcp__emacs__write_file"
	}
	_ = asker.conn.Notify("edit/propose", map[string]any{
		"requestId": req.id, "sessionId": p.SessionID, "kind": p.Kind, "filePath": path,
		"oldString": p.OldString, "newString": p.NewString, "replaceAll": p.ReplaceAll, "content": p.Content,
	})
	d.broadcast(p.SessionID, session.Update{
		"kind": "edit", "state": "pending", "requestId": req.id, "editKind": p.Kind,
		"filePath": path, "relPath": rel,
		"title": session.ToolTitle(toolName, map[string]any{"file_path": path}, e.s.Cwd()),
	})

	withdrawn := func(reason string) {
		_ = asker.conn.Notify("edit/withdraw", map[string]any{"requestId": req.id, "reason": reason})
		d.broadcast(p.SessionID, session.Update{
			"kind": "edit", "state": "withdrawn", "requestId": req.id, "reason": reason,
		})
	}
	select {
	case a := <-req.answer:
		d.broadcast(p.SessionID, session.Update{
			"kind": "edit", "state": a.Outcome, "requestId": req.id,
			"message": a.Message, "saved": a.Saved, "created": a.Created,
		})
		return editOutcome(rel, a), nil
	case reason := <-req.withdraw:
		withdrawn(reason)
		return failed("The edit was not made: " + reason)
	case <-ctx.Done():
		withdrawn("Claude no longer needs an answer.")
		return nil, ctx.Err()
	}
}

// editOutcome is what Claude reads as the edit tool's result.
func editOutcome(rel string, a editAnswer) toolResult {
	switch a.Outcome {
	case "applied":
		switch {
		case a.Created:
			return toolResult{Text: "The user accepted the new file " + rel + "; it is created and saved."}
		case a.Saved:
			return toolResult{Text: "The user applied the edit to " + rel + " in Emacs, and it is saved."}
		default:
			return toolResult{Text: "The user applied the edit to " + rel + " in Emacs. It is not saved yet, " +
				"because that buffer has unsaved changes of the user's, so commands that read the file from " +
				"disk still see the old version."}
		}
	case "rejected":
		text := "The user rejected this edit to " + rel + "."
		if a.Message != "" {
			text += " Their note: " + a.Message
		}
		return toolResult{Text: text + " Do not send the same change again.", IsError: true}
	default:
		message := a.Message
		if message == "" {
			message = "Emacs could not make the edit."
		}
		return toolResult{Text: message, IsError: true}
	}
}

func (d *Daemon) answerEdit(c *client, params json.RawMessage) (any, error) {
	if c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "edit/answer is for Emacs")
	}
	var p struct {
		RequestID string `json:"requestId"`
		editAnswer
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.RequestID == "" ||
		(p.Outcome != "applied" && p.Outcome != "rejected" && p.Outcome != "error") {
		return nil, rpc.Errorf(protocol.InvalidParams, `edit/answer needs a requestId and an outcome of "applied", "rejected" or "error"`)
	}
	d.mu.Lock()
	req := d.edits[p.RequestID]
	d.mu.Unlock()
	if req == nil {
		return nil, rpc.Errorf(protocol.UnknownRequest, "no pending edit %q; it was answered or withdrawn", p.RequestID)
	}
	if req.asker != c {
		return nil, rpc.Errorf(protocol.UnknownRequest, "edit %q is being reviewed in another Emacs", p.RequestID)
	}
	select {
	case req.answer <- p.editAnswer:
		return map[string]bool{"ok": true}, nil
	default:
		return nil, rpc.Errorf(protocol.UnknownRequest, "edit %q was already answered", p.RequestID)
	}
}

// insideProject returns path cleaned, or an error unless it is an absolute
// path inside cwd. Symbolic links are resolved, so a link cannot lead out.
func insideProject(cwd, path string) (string, error) {
	if path == "" || !filepath.IsAbs(path) {
		return "", errors.New("file_path must be an absolute path, got " + quote(path))
	}
	clean := filepath.Clean(path)
	root, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		return "", err
	}
	// Resolve the deepest part of the path that exists; the rest is new.
	existing, rest := clean, ""
	for {
		resolved, err := filepath.EvalSymlinks(existing)
		if err == nil {
			existing = resolved
			break
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			break
		}
		rest = filepath.Join(filepath.Base(existing), rest)
		existing = parent
	}
	full := filepath.Join(existing, rest)
	if rel, err := filepath.Rel(root, full); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", errors.New("claude-pair only edits files inside the project " + cwd + ", not " + clean)
	}
	return clean, nil
}

func relativeTo(cwd, path string) string {
	if rel, err := filepath.Rel(cwd, path); err == nil && !strings.HasPrefix(rel, "..") {
		return rel
	}
	return path
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
