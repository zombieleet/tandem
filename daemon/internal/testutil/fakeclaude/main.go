// Command fakeclaude stands in for Claude Code in tests. It speaks the same
// headless stream-json protocol, with events shaped like ones recorded from
// Claude Code 2.1.327, and never calls a model.
//
// A prompt "script:NAME[:ARG]" picks a scenario: hello, args, nostream,
// tools, slow:N, crash, fail, subagent, bash:CMD, bash2:CMD (the same
// command twice), sleepbash:MS:CMD, webfetch:URL, and edit:JSON or
// write:JSON, where JSON holds file (relative to the working directory),
// old, new and all, or file and content. Edits call the emacs server's
// edit_file or write_file over MCP, asking permission first unless
// --allowedTools allows them. mcp:TOOL:JSON calls the emacs server's TOOL
// with the arguments JSON, the same way; several calls can be chained with
// " && ". Any other prompt is echoed back.
//
// For bash and webfetch it asks --permission-prompt-tool through the MCP
// server in --mcp-config, as Claude Code does, and applies "always" rules
// it gets back to later calls. Without a permission tool it denies.
// FAKE_CLAUDE_EVENTS_LOG names a file that gets one line per decision.
// SIGINT during a turn ends it as Claude Code does: an error_during_execution
// result, then exit 0. FAKE_CLAUDE_VERSION sets the --version output, and
// FAKE_CLAUDE_ARGS_LOG names a file that gets one line of arguments per start.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var (
	out         = bufio.NewWriter(os.Stdout)
	sessionID   string
	totalCost   float64
	turns       int
	interrupted atomic.Bool
	msgCounter  int

	mcpConfig  string
	permTool   string
	allowed    = map[string]bool{}
	mcpSession *mcp.ClientSession
	rules      []map[string]any // allow rules from "always" answers

	callMu     sync.Mutex
	callCancel context.CancelFunc
)

func main() {
	args := os.Args[1:]
	if len(args) == 1 && args[0] == "--version" {
		v := os.Getenv("FAKE_CLAUDE_VERSION")
		if v == "" {
			v = "2.1.327"
		}
		fmt.Printf("%s (Claude Code)\n", v)
		return
	}
	if path := os.Getenv("FAKE_CLAUDE_ARGS_LOG"); path != "" {
		if f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			fmt.Fprintln(f, strings.Join(args, " "))
			f.Close()
		}
	}
	for i, a := range args {
		if i+1 >= len(args) {
			break
		}
		switch a {
		case "--session-id", "--resume":
			sessionID = args[i+1]
		case "--mcp-config":
			mcpConfig = args[i+1]
		case "--permission-prompt-tool":
			permTool = args[i+1]
		case "--allowedTools":
			for _, t := range strings.Split(args[i+1], ",") {
				allowed[strings.TrimSpace(t)] = true
			}
		}
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt)
	busy := atomic.Bool{}
	go func() {
		for range sigs {
			if !busy.Load() {
				os.Exit(0)
			}
			interrupted.Store(true)
			callMu.Lock()
			if callCancel != nil {
				callCancel()
			}
			callMu.Unlock()
		}
	}()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	initDone := false
	for scanner.Scan() {
		var msg struct {
			Type    string `json:"type"`
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(scanner.Bytes(), &msg) != nil || msg.Type != "user" {
			continue
		}
		if !initDone {
			cwd, _ := os.Getwd()
			emit(map[string]any{
				"type": "system", "subtype": "init", "cwd": cwd, "session_id": sessionID,
				"tools": []string{"Read", "Glob", "Grep", "Bash"}, "model": "claude-fake-1",
				"permissionMode": "default", "slash_commands": []string{"compact", "review"},
				"claude_code_version": "2.1.327",
			})
			initDone = true
		}
		busy.Store(true)
		turn(msg.Message.Content, args)
		busy.Store(false)
	}
}

func turn(prompt string, args []string) {
	emit(map[string]any{"type": "system", "subtype": "status", "status": "requesting", "session_id": sessionID})
	name, arg := "echo", ""
	if rest, ok := strings.CutPrefix(prompt, "script:"); ok {
		name, arg, _ = strings.Cut(rest, ":")
	}
	switch name {
	case "hello":
		streamText([]string{"Hel", "lo ", "wörld 🌍"}, 0)
		result("success", false, nil)
	case "args":
		streamText([]string{strings.Join(args, " ")}, 0)
		result("success", false, nil)
	case "nostream":
		assistant(nextMsg(), map[string]any{"type": "text", "text": "Not streamed."})
		result("success", false, nil)
	case "tools":
		tools()
	case "slow":
		n, _ := strconv.Atoi(arg)
		if n == 0 {
			n = 2000
		}
		chunks := make([]string, n)
		for i := range chunks {
			chunks[i] = fmt.Sprintf("%d\n", i+1)
		}
		if streamText(chunks, 20*time.Millisecond) {
			result("success", false, nil)
		}
	case "bash", "bash2", "webfetch":
		permissionScenario(name, arg)
	case "edit", "write":
		editScenario(name, arg)
	case "mcp":
		mcpScenario(arg)
	case "sleepbash": // sleepbash:MS:CMD waits MS milliseconds, then asks to run CMD
		ms, cmd, _ := strings.Cut(arg, ":")
		n, _ := strconv.Atoi(ms)
		time.Sleep(time.Duration(n) * time.Millisecond)
		permissionScenario("bash", cmd)
	case "crash":
		fmt.Fprintln(os.Stderr, "fatal: something broke")
		out.Flush()
		os.Exit(3)
	case "fail":
		result("error_max_turns", true, map[string]any{"result": "Reached the maximum number of turns"})
	case "subagent":
		parent := "toolu_task1"
		assistant(nextMsg(), map[string]any{"type": "tool_use", "id": parent, "name": "Task",
			"input": map[string]any{"description": "Look around", "prompt": "..."}})
		emitFrom(parent, map[string]any{"type": "stream_event", "event": map[string]any{
			"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "SUBAGENT TEXT"}}})
		toolResult(parent, "found it", false)
		streamText([]string{"Main."}, 0)
		result("success", false, nil)
	default:
		streamText([]string{"You said: ", prompt}, 0)
		result("success", false, nil)
	}
}

func permissionScenario(name, arg string) {
	times := 1
	if name == "bash2" {
		times = 2
	}
	var summary []string
	var denials []map[string]any
	for i := range times {
		toolID := fmt.Sprintf("toolu_p%d_%d", turns, i)
		tool, input := "Bash", map[string]any{"command": arg, "description": "Run it"}
		if name == "webfetch" {
			tool, input = "WebFetch", map[string]any{"url": arg, "prompt": "Summarize"}
		}
		assistant(nextMsg(), map[string]any{"type": "tool_use", "id": toolID, "name": tool, "input": input})
		if rule := matchingRule(tool, input); rule != "" {
			logEvent("%s %s -> allowed by rule %s", tool, arg, rule)
			toolResult(toolID, "ran: "+arg, false)
			summary = append(summary, "allowed by rule: "+arg)
			continue
		}
		decision, err := ask(tool, input, toolID)
		if interrupted.Load() {
			interruptTurn(nextMsg(), "")
		}
		if err != nil {
			logEvent("%s %s -> error %v", tool, arg, err)
			toolResult(toolID, "permission tool failed: "+err.Error(), true)
			summary = append(summary, "permission tool failed: "+err.Error())
			denials = append(denials, map[string]any{"tool_name": tool, "tool_use_id": toolID, "tool_input": input})
			continue
		}
		if decision["behavior"] == "allow" {
			saved := saveRules(decision["updatedPermissions"])
			logEvent("%s %s -> allow%s", tool, arg, saved)
			toolResult(toolID, "ran: "+arg, false)
			summary = append(summary, "allowed: "+arg+saved)
		} else {
			message, _ := decision["message"].(string)
			logEvent("%s %s -> deny %s", tool, arg, message)
			toolResult(toolID, "denied: "+message, true)
			summary = append(summary, "denied: "+message)
			denials = append(denials, map[string]any{"tool_name": tool, "tool_use_id": toolID, "tool_input": input})
		}
	}
	streamText([]string{strings.Join(summary, "\n")}, 0)
	result("success", false, map[string]any{"permission_denials": denials})
}

// callTool calls an MCP tool, given by its full mcp__server__tool name, and
// returns its one text block. SIGINT cancels the call.
func callTool(fullName string, args map[string]any) (string, bool, *mcp.CallToolResult, error) {
	server, toolName, ok := strings.Cut(strings.TrimPrefix(fullName, "mcp__"), "__")
	if !ok {
		return "", false, nil, fmt.Errorf("bad MCP tool name %q", fullName)
	}
	if mcpSession == nil {
		cs, err := connect(server)
		if err != nil {
			return "", false, nil, err
		}
		mcpSession = cs
	}
	ctx, cancel := context.WithCancel(context.Background())
	callMu.Lock()
	callCancel = cancel
	callMu.Unlock()
	defer func() {
		callMu.Lock()
		callCancel = nil
		callMu.Unlock()
		cancel()
	}()
	res, err := mcpSession.CallTool(ctx, &mcp.CallToolParams{Name: toolName, Arguments: args})
	if err != nil {
		return "", false, nil, err
	}
	text := ""
	if len(res.Content) == 1 {
		if t, ok := res.Content[0].(*mcp.TextContent); ok {
			text = t.Text
		}
	}
	return text, res.IsError, res, nil
}

// ask calls the permission prompt tool the way Claude Code does, and checks
// the answer as strictly: exactly one text block, no structured content.
func ask(tool string, input map[string]any, toolUseID string) (map[string]any, error) {
	if permTool == "" {
		return map[string]any{"behavior": "deny", "message": "no permission prompt tool"}, nil
	}
	_, _, res, err := callTool(permTool, map[string]any{
		"tool_name": tool, "input": input, "tool_use_id": toolUseID,
	})
	if err != nil {
		return nil, err
	}
	if res.StructuredContent != nil || len(res.Content) != 1 {
		return nil, errors.New("Permission prompt tool returned an invalid result. Expected a single text block")
	}
	text, ok := res.Content[0].(*mcp.TextContent)
	if !ok {
		return nil, errors.New("Permission prompt tool returned an invalid result. Expected a single text block")
	}
	var decision map[string]any
	if err := json.Unmarshal([]byte(text.Text), &decision); err != nil {
		return nil, fmt.Errorf("Permission prompt tool returned invalid JSON: %v", err)
	}
	return decision, nil
}

// editScenario calls edit_file or write_file once and reports the result.
func editScenario(name, arg string) {
	var spec struct {
		File, Old, New, Content string
		All                     bool
	}
	if err := json.Unmarshal([]byte(arg), &spec); err != nil {
		streamText([]string{"bad edit spec: " + err.Error()}, 0)
		result("success", false, nil)
		return
	}
	cwd, _ := os.Getwd()
	path := spec.File
	if !filepath.IsAbs(path) {
		path = filepath.Join(cwd, path)
	}
	tool := "mcp__emacs__edit_file"
	input := map[string]any{"file_path": path, "old_string": spec.Old, "new_string": spec.New}
	if spec.All {
		input["replace_all"] = true
	}
	if name == "write" {
		tool, input = "mcp__emacs__write_file", map[string]any{"file_path": path, "content": spec.Content}
	}
	toolID := fmt.Sprintf("toolu_e%d", turns)
	assistant(nextMsg(), map[string]any{"type": "tool_use", "id": toolID, "name": tool, "input": input})
	if !allowed[tool] {
		decision, err := ask(tool, input, toolID)
		if err != nil || decision["behavior"] != "allow" {
			toolResult(toolID, "permission denied", true)
			streamText([]string{"edit result: permission denied"}, 0)
			result("success", false, nil)
			return
		}
	}
	text, isError, _, err := callTool(tool, input)
	if interrupted.Load() {
		interruptTurn(nextMsg(), "")
	}
	if err != nil {
		text, isError = "tool call failed: "+err.Error(), true
	}
	logEvent("%s %s -> error=%v %s", tool, spec.File, isError, text)
	toolResult(toolID, text, isError)
	streamText([]string{"edit result: " + text}, 0)
	result("success", false, nil)
}

// mcpScenario calls emacs tools, one per "TOOL:JSON" step, in one turn, and
// reports each result as "TOOL result: TEXT" (with " (error)" on errors).
func mcpScenario(arg string) {
	var report []string
	for i, step := range strings.Split(arg, " && ") {
		name, rawArgs, _ := strings.Cut(step, ":")
		args := map[string]any{}
		if rawArgs != "" {
			if err := json.Unmarshal([]byte(rawArgs), &args); err != nil {
				report = append(report, "bad mcp args: "+err.Error())
				continue
			}
		}
		tool := "mcp__emacs__" + name
		toolID := fmt.Sprintf("toolu_m%d_%d", turns, i)
		assistant(nextMsg(), map[string]any{"type": "tool_use", "id": toolID, "name": tool, "input": args})
		if !allowed[tool] {
			decision, err := ask(tool, args, toolID)
			if err != nil || decision["behavior"] != "allow" {
				toolResult(toolID, "permission denied", true)
				report = append(report, name+" result: permission denied")
				continue
			}
		}
		text, isError, _, err := callTool(tool, args)
		if err != nil {
			text, isError = "tool call failed: "+err.Error(), true
		}
		logEvent("%s -> error=%v %s", tool, isError, text)
		toolResult(toolID, text, isError)
		line := name + " result: " + text
		if isError {
			line += " (error)"
		}
		report = append(report, line)
	}
	streamText([]string{strings.Join(report, "\n")}, 0)
	result("success", false, nil)
}

func connect(server string) (*mcp.ClientSession, error) {
	var config struct {
		MCPServers map[string]struct {
			Type    string   `json:"type"`
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(mcpConfig), &config); err != nil {
		return nil, fmt.Errorf("bad --mcp-config: %v", err)
	}
	entry, ok := config.MCPServers[server]
	if !ok || entry.Type != "stdio" {
		return nil, fmt.Errorf("no stdio MCP server %q in --mcp-config", server)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "fakeclaude", Version: "2.1.327"}, nil)
	return client.Connect(context.Background(), &mcp.CommandTransport{Command: exec.Command(entry.Command, entry.Args...)}, nil)
}

// saveRules keeps addRules entries and describes them, like " (rule: Bash(x))".
func saveRules(v any) string {
	updates, _ := v.([]any)
	var saved []string
	for _, u := range updates {
		update, _ := u.(map[string]any)
		if update["type"] != "addRules" || update["behavior"] != "allow" {
			continue
		}
		list, _ := update["rules"].([]any)
		for _, r := range list {
			rule, _ := r.(map[string]any)
			rules = append(rules, rule)
			text, _ := rule["toolName"].(string)
			if content, _ := rule["ruleContent"].(string); content != "" {
				text += "(" + content + ")"
			}
			saved = append(saved, fmt.Sprintf("%s in %s", text, update["destination"]))
		}
	}
	if len(saved) == 0 {
		return ""
	}
	return " (rule: " + strings.Join(saved, ", ") + ")"
}

func matchingRule(tool string, input map[string]any) string {
	for _, rule := range rules {
		if rule["toolName"] != tool {
			continue
		}
		content, _ := rule["ruleContent"].(string)
		cmd, _ := input["command"].(string)
		if content == "" || content == cmd {
			return fmt.Sprint(rule["toolName"], "(", content, ")")
		}
	}
	return ""
}

func logEvent(format string, a ...any) {
	path := os.Getenv("FAKE_CLAUDE_EVENTS_LOG")
	if path == "" {
		return
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
		fmt.Fprintf(f, format+"\n", a...)
		f.Close()
	}
}

func tools() {
	cwd, _ := os.Getwd()
	first := nextMsg()
	streamTextAs(first, []string{"Looking."}, 0)
	assistant(first, map[string]any{"type": "tool_use", "id": "toolu_r1", "name": "Read",
		"input": map[string]any{"file_path": filepath.Join(cwd, "README.md")}})
	time.Sleep(30 * time.Millisecond)
	toolResult("toolu_r1", "readme text", false)
	second := nextMsg()
	assistant(second, map[string]any{"type": "tool_use", "id": "toolu_t1", "name": "TodoWrite",
		"input": map[string]any{"todos": []map[string]any{
			{"content": "Read the README", "status": "completed", "activeForm": "Reading the README"},
			{"content": "Summarize it", "status": "in_progress", "activeForm": "Summarizing"},
		}}})
	toolResult("toolu_t1", "ok", false)
	assistant(second, map[string]any{"type": "tool_use", "id": "toolu_b1", "name": "Bash",
		"input": map[string]any{"command": "rm -rf build\necho done", "description": "Clean"}})
	toolResult("toolu_b1", "Permission to use Bash was denied", true)
	streamText([]string{"Done."}, 0)
	result("success", false, map[string]any{"permission_denials": []map[string]any{
		{"tool_name": "Bash", "tool_use_id": "toolu_b1", "tool_input": map[string]any{"command": "rm -rf build"}},
	}})
}

// streamText streams chunks as one assistant message. It returns false if
// SIGINT interrupted it, after emitting what Claude Code emits then.
func streamText(chunks []string, delay time.Duration) bool {
	return streamTextAs(nextMsg(), chunks, delay)
}

func streamTextAs(id string, chunks []string, delay time.Duration) bool {
	emit(streamEvent(id, map[string]any{"type": "message_start", "message": map[string]any{
		"id": id, "type": "message", "role": "assistant", "content": []any{}}}))
	emit(streamEvent(id, map[string]any{"type": "content_block_start", "index": 0,
		"content_block": map[string]any{"type": "text", "text": ""}}))
	var text strings.Builder
	for _, c := range chunks {
		if interrupted.Load() {
			emit(streamEvent(id, map[string]any{"type": "content_block_stop", "index": 0}))
			emit(streamEvent(id, map[string]any{"type": "message_stop"}))
			interruptTurn(id, text.String())
		}
		text.WriteString(c)
		emit(streamEvent(id, map[string]any{"type": "content_block_delta", "index": 0,
			"delta": map[string]any{"type": "text_delta", "text": c}}))
		if delay > 0 {
			time.Sleep(delay)
		}
	}
	emit(streamEvent(id, map[string]any{"type": "content_block_stop", "index": 0}))
	emit(streamEvent(id, map[string]any{"type": "message_stop"}))
	assistant(id, map[string]any{"type": "text", "text": text.String()})
	return true
}

// interruptTurn ends the turn as Claude Code does after SIGINT, and exits.
func interruptTurn(id, partial string) {
	if partial != "" {
		assistant(id, map[string]any{"type": "text", "text": partial})
	}
	emit(map[string]any{"type": "user", "parent_tool_use_id": nil, "session_id": sessionID,
		"message": map[string]any{"role": "user", "content": []map[string]any{
			{"type": "text", "text": "[Request interrupted by user]"}}}})
	result("error_during_execution", true, nil)
	out.Flush()
	if mcpSession != nil {
		mcpSession.Close()
	}
	os.Exit(0)
}

func nextMsg() string {
	msgCounter++
	return fmt.Sprintf("msg_fake_%d", msgCounter)
}

func streamEvent(id string, event map[string]any) map[string]any {
	return map[string]any{"type": "stream_event", "event": event, "session_id": sessionID,
		"parent_tool_use_id": nil, "api_message_id": id}
}

func assistant(id string, block map[string]any) {
	emit(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "session_id": sessionID,
		"message": map[string]any{"id": id, "type": "message", "role": "assistant",
			"content": []map[string]any{block}, "stop_reason": nil}})
}

func toolResult(id, content string, isError bool) {
	emit(map[string]any{"type": "user", "parent_tool_use_id": nil, "session_id": sessionID,
		"message": map[string]any{"role": "user", "content": []map[string]any{
			{"tool_use_id": id, "type": "tool_result", "content": content, "is_error": isError}}}})
}

func result(subtype string, isError bool, extra map[string]any) {
	turns++
	totalCost += 0.01
	r := map[string]any{
		"type": "result", "subtype": subtype, "is_error": isError, "duration_ms": 1234,
		"num_turns": turns, "session_id": sessionID, "total_cost_usd": totalCost,
		"usage": map[string]any{"input_tokens": 10, "output_tokens": 20,
			"cache_read_input_tokens": 300, "cache_creation_input_tokens": 40},
		"permission_denials": []any{},
	}
	for k, v := range extra {
		r[k] = v
	}
	emit(r)
}

func emitFrom(parent string, event map[string]any) {
	event["parent_tool_use_id"] = parent
	event["session_id"] = sessionID
	emit(event)
}

func emit(v map[string]any) {
	line, _ := json.Marshal(v)
	out.Write(line)
	out.WriteByte('\n')
	out.Flush()
}
