package server

import (
	"context"
	"encoding/json"
	"path/filepath"
	"time"

	"github.com/zombieleet/tandem/daemon/internal/protocol"
	"github.com/zombieleet/tandem/daemon/internal/rpc"
)

// A window tool call travels like this: Claude calls open_file,
// close_window or list_windows on the MCP helper; the helper sends
// helper/emacs here; the daemon checks the path, if any, and sends
// tool/call to the Emacs that answers for the session; Emacs applies its
// layout rules and answers with tool/result, which becomes the tool's
// result. Emacs, not the daemon, decides and enforces the window rules.

// EmacsToolTimeout is how long Emacs has to answer a window tool call.
var EmacsToolTimeout = 30 * time.Second

var emacsTools = map[string]bool{"open_file": true, "close_window": true, "list_windows": true,
	"diagnostics": true, "xref": true, "imenu": true, "selection": true}

// toolsWithPaths read a file the daemon must keep inside the project; the
// verb says so in the refusal.
var toolsWithPaths = map[string]string{"open_file": "shows", "diagnostics": "reads", "xref": "reads", "imenu": "reads"}

type pendingTool struct {
	id     string
	asker  *client
	result chan toolResult
}

func (d *Daemon) callEmacs(ctx context.Context, c *client, params json.RawMessage) (any, error) {
	if !c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "helper/emacs is for the MCP helper only")
	}
	var p struct {
		SessionID string         `json:"sessionId"`
		Tool      string         `json:"tool"`
		Args      map[string]any `json:"args"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.SessionID == "" || !emacsTools[p.Tool] {
		return nil, rpc.Errorf(protocol.InvalidParams,
			`helper/emacs needs a sessionId and one of Emacs's tools: open_file, close_window, list_windows, diagnostics, xref, imenu, selection`)
	}
	if p.Args == nil {
		p.Args = map[string]any{}
	}
	failed := func(text string) (any, error) { return toolResult{Text: text, IsError: true}, nil }

	d.mu.Lock()
	e := d.sessions[p.SessionID]
	asker := d.askerLocked(e)
	d.mu.Unlock()
	if e == nil {
		return failed("tandem has no such session.")
	}
	if verb, ok := toolsWithPaths[p.Tool]; ok {
		path, _ := p.Args["path"].(string)
		switch {
		case path == "" && p.Tool == "diagnostics":
			// Every open file of the project.
		case path == "":
			return failed(p.Tool + " needs a path.")
		default:
			if path = onDrive(e.s.Cwd(), path); !filepath.IsAbs(path) {
				path = filepath.Join(e.s.Cwd(), path)
			}
			full, err := insideProject(e.s.Cwd(), path, verb)
			if err != nil {
				return failed(err.Error())
			}
			p.Args["path"] = full
		}
	}
	if asker == nil {
		return failed("No Emacs is connected, so there are no windows to work with.")
	}

	req := &pendingTool{id: newRequestID("tool-"), asker: asker, result: make(chan toolResult, 1)}
	d.mu.Lock()
	d.tools[req.id] = req
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.tools, req.id)
		d.mu.Unlock()
	}()
	_ = asker.conn.Notify("tool/call", map[string]any{
		"requestId": req.id, "sessionId": p.SessionID, "tool": p.Tool, "args": p.Args, "root": e.s.Cwd(),
	})
	timer := time.NewTimer(EmacsToolTimeout)
	defer timer.Stop()
	select {
	case r := <-req.result:
		return r, nil
	case <-asker.conn.Done():
		return failed("Emacs disconnected before it answered.")
	case <-timer.C:
		return failed("Emacs did not answer within " + EmacsToolTimeout.String() + ".")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (d *Daemon) answerTool(c *client, params json.RawMessage) (any, error) {
	if c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "tool/result is for Emacs")
	}
	var p struct {
		RequestID string `json:"requestId"`
		toolResult
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.RequestID == "" {
		return nil, rpc.Errorf(protocol.InvalidParams, "tool/result needs a requestId and a text")
	}
	d.mu.Lock()
	req := d.tools[p.RequestID]
	d.mu.Unlock()
	if req == nil {
		return nil, rpc.Errorf(protocol.UnknownRequest, "no pending tool call %q; it was answered or timed out", p.RequestID)
	}
	if req.asker != c {
		return nil, rpc.Errorf(protocol.UnknownRequest, "tool call %q was sent to another Emacs", p.RequestID)
	}
	select {
	case req.result <- p.toolResult:
		return map[string]bool{"ok": true}, nil
	default:
		return nil, rpc.Errorf(protocol.UnknownRequest, "tool call %q was already answered", p.RequestID)
	}
}
