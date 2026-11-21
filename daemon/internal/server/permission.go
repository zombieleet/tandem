package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"time"

	"github.com/victory/claude-pair/daemon/internal/mcphelper"
	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/rpc"
	"github.com/victory/claude-pair/daemon/internal/session"
)

// A permission request travels like this: Claude Code calls the MCP
// helper's permission tool; the helper sends helper/permission here; the
// daemon shows it to Emacs as a session/update of kind "permission"; Emacs
// answers with permission/answer; the helper returns the decision to Claude
// Code. A cancelled turn, a closed session or a departed helper withdraws it.

type permissionAnswer struct {
	Decision string `json:"decision"`
	Always   bool   `json:"always"`
	Message  string `json:"message"`
	// UpdatedInput replaces the tool's input when allowed: for
	// ExitPlanMode, the plan as the user edited it.
	UpdatedInput json.RawMessage `json:"updatedInput"`
}

type pendingPermission struct {
	id        string
	sessionID string
	answer    chan permissionAnswer // buffered 1: the first answer wins
	withdraw  chan string           // buffered 1: the reason
}

// askPermission handles helper/permission and waits for the user.
func (d *Daemon) askPermission(ctx context.Context, c *client, params json.RawMessage) (any, error) {
	if !c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "helper/permission is for the MCP helper only")
	}
	var p struct {
		SessionID string          `json:"sessionId"`
		ToolName  string          `json:"toolName"`
		ToolUseID string          `json:"toolUseId"`
		Input     json.RawMessage `json:"input"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.SessionID == "" || p.ToolName == "" {
		return nil, rpc.Errorf(protocol.InvalidParams, "helper/permission needs a sessionId and a toolName")
	}
	if len(p.Input) == 0 || string(p.Input) == "null" {
		p.Input = json.RawMessage("{}")
	}
	if p.ToolName == mcphelper.EditToolName || p.ToolName == mcphelper.WriteToolName ||
		mcphelper.IsLayoutTool(p.ToolName) {
		// The edit tools ask the user themselves, inside Emacs.
		return allow(p.Input, Rule{}, false), nil
	}
	var input map[string]any
	_ = json.Unmarshal(p.Input, &input)

	d.mu.Lock()
	e := d.sessions[p.SessionID]
	asker := d.askerLocked(e)
	d.mu.Unlock()
	if e == nil {
		return deny("claude-pair has no such session, so it denied this."), nil
	}
	if asker == nil {
		return deny("No Emacs is connected to answer this permission prompt, so claude-pair denied it."), nil
	}
	// The question comes through the helper, Claude's words through its
	// output: wait until the output has reached the tool call, so Emacs
	// gets what Claude wrote before it first (a plan, say).
	if p.ToolUseID != "" {
		e.s.WaitForTool(ctx, p.ToolUseID, 2*time.Second)
	}

	req := &pendingPermission{
		id:        newRequestID("perm-"),
		sessionID: p.SessionID,
		answer:    make(chan permissionAnswer, 1),
		withdraw:  make(chan string, 1),
	}
	d.mu.Lock()
	d.permissions[req.id] = req
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.permissions, req.id)
		d.mu.Unlock()
	}()

	rule := AlwaysRule(p.ToolName, input)
	d.broadcast(p.SessionID, session.Update{
		"kind": "permission", "state": "pending", "requestId": req.id,
		"toolName": p.ToolName, "toolUseId": p.ToolUseID, "input": input,
		"title":      session.ToolTitle(p.ToolName, input, e.s.Cwd()),
		"alwaysRule": rule.String(),
	})

	select {
	case a := <-req.answer:
		d.broadcast(p.SessionID, session.Update{
			"kind": "permission", "state": "answered", "requestId": req.id,
			"decision": a.Decision, "always": a.Always, "message": a.Message,
		})
		if a.Decision != "allow" {
			message := a.Message
			if message == "" {
				message = "The user denied this."
			}
			return deny(message), nil
		}
		input := p.Input
		if len(a.UpdatedInput) > 0 && string(a.UpdatedInput) != "null" {
			input = a.UpdatedInput
		}
		return allow(input, rule, a.Always), nil
	case reason := <-req.withdraw:
		d.broadcast(p.SessionID, session.Update{
			"kind": "permission", "state": "withdrawn", "requestId": req.id, "reason": reason,
		})
		return deny(reason), nil
	case <-ctx.Done():
		d.broadcast(p.SessionID, session.Update{
			"kind": "permission", "state": "withdrawn", "requestId": req.id,
			"reason": "Claude no longer needs an answer.",
		})
		return nil, ctx.Err()
	}
}

// answerPermission handles permission/answer from Emacs.
func (d *Daemon) answerPermission(c *client, params json.RawMessage) (any, error) {
	if c.helper() {
		return nil, rpc.Errorf(protocol.MethodNotFound, "permission/answer is for Emacs")
	}
	var p struct {
		RequestID string `json:"requestId"`
		permissionAnswer
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.RequestID == "" ||
		(p.Decision != "allow" && p.Decision != "deny") {
		return nil, rpc.Errorf(protocol.InvalidParams, `permission/answer needs a requestId and a decision of "allow" or "deny"`)
	}
	d.mu.Lock()
	req := d.permissions[p.RequestID]
	d.mu.Unlock()
	if req == nil {
		return nil, rpc.Errorf(protocol.UnknownRequest, "no pending permission request %q; it was answered or withdrawn", p.RequestID)
	}
	select {
	case req.answer <- p.permissionAnswer:
		return map[string]bool{"ok": true}, nil
	default:
		return nil, rpc.Errorf(protocol.UnknownRequest, "permission request %q was already answered", p.RequestID)
	}
}

// withdrawPermissions cancels every open question and edit of a session.
func (d *Daemon) withdrawPermissions(sessionID, reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, req := range d.permissions {
		if req.sessionID == sessionID {
			select {
			case req.withdraw <- reason:
			default:
			}
		}
	}
	for _, req := range d.edits {
		if req.sessionID == sessionID {
			select {
			case req.withdraw <- reason:
			default:
			}
		}
	}
}

// askerLocked picks the client that answers a session's permission prompts:
// the one that sent the last prompt if it is still here, else any follower.
func (d *Daemon) askerLocked(e *sessionEntry) *client {
	if e == nil {
		return nil
	}
	if e.last != nil && e.subs[e.last] && !e.last.helper() {
		return e.last
	}
	for c := range e.subs {
		if !c.helper() {
			return c
		}
	}
	return nil
}

// Rule is the permission rule "always allow" adds, such as Bash(make test).
type Rule struct {
	ToolName    string
	RuleContent string // empty: the whole tool
}

func (r Rule) String() string {
	if r.RuleContent == "" {
		return r.ToolName
	}
	return r.ToolName + "(" + r.RuleContent + ")"
}

// AlwaysRule is the narrowest rule that covers this call: the exact Bash
// command, a WebFetch domain, or else the whole tool.
func AlwaysRule(toolName string, input map[string]any) Rule {
	switch toolName {
	case "Bash":
		if cmd, _ := input["command"].(string); cmd != "" {
			return Rule{ToolName: toolName, RuleContent: cmd}
		}
	case "WebFetch":
		if raw, _ := input["url"].(string); raw != "" {
			if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
				return Rule{ToolName: toolName, RuleContent: "domain:" + u.Hostname()}
			}
		}
	}
	return Rule{ToolName: toolName}
}

func allow(input json.RawMessage, rule Rule, always bool) json.RawMessage {
	answer := map[string]any{"behavior": "allow", "updatedInput": input}
	if always {
		r := map[string]string{"toolName": rule.ToolName}
		if rule.RuleContent != "" {
			r["ruleContent"] = rule.RuleContent
		}
		// Claude Code applies the rule at once and saves it in the project's
		// .claude/settings.local.json, as its own "don't ask again" does.
		answer["updatedPermissions"] = []map[string]any{{
			"type": "addRules", "behavior": "allow", "destination": "localSettings",
			"rules": []map[string]string{r},
		}}
	}
	b, _ := json.Marshal(answer)
	return b
}

func deny(message string) json.RawMessage {
	b, _ := json.Marshal(map[string]string{"behavior": "deny", "message": message})
	return b
}

func newRequestID(prefix string) string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return prefix + hex.EncodeToString(b[:])
}
