package session

import (
	"regexp"
	"strings"
	"time"
)

// localOutput matches what a slash command that runs inside Claude Code,
// such as /compact, prints.
var localOutput = regexp.MustCompile(`(?s)<local-command-std(?:out|err)>(.*?)</local-command-std(?:out|err)>`)

// translate turns one stream-json event into updates. It runs with s.mu held
// and reports whether the event ended a turn. Events from subagents (those
// with a parent_tool_use_id) are left out; their Task tool call shows instead.
func (s *Session) translate(p *process, event map[string]any) ([]Update, bool) {
	if parent, ok := event["parent_tool_use_id"]; ok && parent != nil {
		return nil, false
	}
	switch event["type"] {
	case "system":
		return s.systemEvent(event), false
	case "stream_event":
		return s.streamEvent(p, event), false
	case "assistant":
		return s.assistantEvent(p, event), false
	case "user":
		return s.userEvent(p, event), false
	case "result":
		return s.resultEvent(p, event), true
	}
	return nil, false
}

func (s *Session) systemEvent(event map[string]any) []Update {
	switch event["subtype"] {
	case "init":
		return []Update{{
			"kind":           "init",
			"model":          str(event, "model"),
			"claudeVersion":  str(event, "claude_code_version"),
			"cwd":            str(event, "cwd"),
			"permissionMode": str(event, "permissionMode"),
			"slashCommands":  stringList(event["slash_commands"]),
		}}
	case "status":
		if state := str(event, "status"); state != "" {
			return []Update{{"kind": "status", "state": state}}
		}
	}
	return nil
}

func (s *Session) streamEvent(p *process, event map[string]any) []Update {
	inner := object(event["event"])
	switch inner["type"] {
	case "message_start":
		p.currentMsg = str(object(inner["message"]), "id")
	case "content_block_delta":
		delta := object(inner["delta"])
		if delta["type"] != "text_delta" {
			return nil
		}
		id := str(event, "api_message_id")
		if id == "" {
			id = p.currentMsg
		}
		p.streamed[id] = true
		if text := str(delta, "text"); text != "" {
			return []Update{{"kind": "text", "delta": text}}
		}
	}
	return nil
}

func (s *Session) assistantEvent(p *process, event map[string]any) []Update {
	message := object(event["message"])
	id := str(message, "id")
	var updates []Update
	for _, b := range list(message["content"]) {
		block := object(b)
		switch block["type"] {
		case "text":
			// Text that already streamed as deltas arrives again here, whole.
			if !p.streamed[id] {
				if text := str(block, "text"); text != "" {
					updates = append(updates, Update{"kind": "text", "delta": text})
				}
			}
		case "tool_use":
			toolID, name := str(block, "id"), str(block, "name")
			input := object(block["input"])
			title := ToolTitle(name, input, s.opts.Cwd)
			p.tools[toolID] = toolStart{name: name, title: title, at: time.Now()}
			updates = append(updates, Update{
				"kind": "tool", "id": toolID, "name": name, "title": title, "status": "started",
			})
			if name == "TodoWrite" {
				updates = append(updates, Update{"kind": "todo", "items": todoItems(input["todos"])})
			}
		}
	}
	return updates
}

func (s *Session) userEvent(p *process, event map[string]any) []Update {
	var updates []Update
	if text, ok := object(event["message"])["content"].(string); ok {
		for _, m := range localOutput.FindAllStringSubmatch(text, -1) {
			if out := strings.TrimSpace(m[1]); out != "" {
				updates = append(updates, Update{"kind": "text", "delta": out + "\n"})
			}
		}
		return updates
	}
	for _, b := range list(object(event["message"])["content"]) {
		block := object(b)
		if block["type"] != "tool_result" {
			continue
		}
		toolID := str(block, "tool_use_id")
		start, ok := p.tools[toolID]
		if !ok {
			continue
		}
		delete(p.tools, toolID)
		status := "done"
		if isErr, _ := block["is_error"].(bool); isErr {
			status = "error"
		}
		updates = append(updates, Update{
			"kind": "tool", "id": toolID, "name": start.name, "title": start.title, "status": status,
			"durationMs": time.Since(start.at).Milliseconds(),
		})
	}
	return updates
}

func (s *Session) resultEvent(p *process, event map[string]any) []Update {
	// total_cost_usd counts everything since this process started, so the
	// turn's own cost is the difference from the previous result.
	cost, _ := event["total_cost_usd"].(float64)
	turnCost := cost - p.cost
	if turnCost < 0 {
		turnCost = cost
	}
	p.cost = cost
	s.totalCost += turnCost

	cancelled := p.cancelling
	p.turnOpen, p.streamed, p.tools = false, map[string]bool{}, map[string]toolStart{}
	if cancelled && s.opts.InterruptByMessage {
		// Interrupted by message, claude goes on taking prompts.
		p.cancelling = false
	} else if cancelled && s.proc == p {
		// Claude Code exits after a cancelled turn; the next prompt starts a
		// new process with --resume instead of writing to this one.
		s.proc = nil
	}

	usage := object(event["usage"])
	var denied []string
	for _, d := range list(event["permission_denials"]) {
		if name := str(object(d), "tool_name"); name != "" {
			denied = append(denied, name)
		}
	}
	isError, _ := event["is_error"].(bool)
	result := Update{
		"kind":           "result",
		"subtype":        str(event, "subtype"),
		"isError":        isError && !cancelled,
		"cancelled":      cancelled,
		"durationMs":     number(event["duration_ms"]),
		"numTurns":       number(event["num_turns"]),
		"costUsd":        turnCost,
		"sessionCostUsd": s.totalCost,
		"usage": map[string]any{
			"inputTokens":         number(usage["input_tokens"]),
			"outputTokens":        number(usage["output_tokens"]),
			"cacheReadTokens":     number(usage["cache_read_input_tokens"]),
			"cacheCreationTokens": number(usage["cache_creation_input_tokens"]),
		},
		"permissionDenials": denied,
	}
	if text := str(event, "result"); isError && !cancelled && text != "" {
		result["message"] = text
	}
	return []Update{result, {"kind": "status", "state": "idle"}}
}

func todoItems(v any) []map[string]any {
	items := []map[string]any{}
	for _, t := range list(v) {
		todo := object(t)
		items = append(items, map[string]any{"content": str(todo, "content"), "status": str(todo, "status")})
	}
	return items
}

func object(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func list(v any) []any {
	l, _ := v.([]any)
	return l
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func stringList(v any) []string {
	out := []string{}
	for _, x := range list(v) {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func number(v any) int64 {
	f, _ := v.(float64)
	return int64(f)
}
