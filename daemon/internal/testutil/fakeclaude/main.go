// Command fakeclaude stands in for Claude Code in tests. It speaks the same
// headless stream-json protocol, with events shaped like ones recorded from
// Claude Code 2.1.327, and never calls a model.
//
// A prompt "script:NAME[:ARG]" picks a scenario: hello, args, nostream,
// tools, slow:N, crash, fail, subagent. Any other prompt is echoed back.
// SIGINT during a turn ends it as Claude Code does: an error_during_execution
// result, then exit 0. FAKE_CLAUDE_VERSION sets the --version output, and
// FAKE_CLAUDE_ARGS_LOG names a file that gets one line of arguments per start.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

var (
	out         = bufio.NewWriter(os.Stdout)
	sessionID   string
	totalCost   float64
	turns       int
	interrupted atomic.Bool
	msgCounter  int
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
		if (a == "--session-id" || a == "--resume") && i+1 < len(args) {
			sessionID = args[i+1]
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
			assistant(id, map[string]any{"type": "text", "text": text.String()})
			emit(map[string]any{"type": "user", "parent_tool_use_id": nil, "session_id": sessionID,
				"message": map[string]any{"role": "user", "content": []map[string]any{
					{"type": "text", "text": "[Request interrupted by user]"}}}})
			result("error_during_execution", true, nil)
			out.Flush()
			os.Exit(0)
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
