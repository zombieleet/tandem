// Package mcphelper is "claude-paird mcp": an MCP server that Claude Code
// starts over stdio. It answers Claude Code's permission prompts, and later
// Claude's edit and window tools, by relaying each call to the daemon over
// its socket.
package mcphelper

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/rpc"
	"github.com/victory/claude-pair/daemon/internal/version"
)

// ServerName and PermissionTool make up the permission tool's full name,
// mcp__emacs__permission, which the daemon passes to --permission-prompt-tool.
const (
	ServerName     = "emacs"
	PermissionTool = "permission"
)

// Full names, as Claude Code knows the tools.
const (
	PermissionToolName = "mcp__" + ServerName + "__" + PermissionTool
	EditToolName       = "mcp__" + ServerName + "__edit_file"
	WriteToolName      = "mcp__" + ServerName + "__write_file"

	OpenFileToolName    = "mcp__" + ServerName + "__open_file"
	CloseWindowToolName = "mcp__" + ServerName + "__close_window"
	ListWindowsToolName = "mcp__" + ServerName + "__list_windows"
)

// LayoutToolNames are the window tools. They change only what the user
// sees, never a file, so they run without asking.
var LayoutToolNames = []string{OpenFileToolName, CloseWindowToolName, ListWindowsToolName}

// IsLayoutTool reports whether name is one of LayoutToolNames.
func IsLayoutTool(name string) bool {
	for _, n := range LayoutToolNames {
		if n == name {
			return true
		}
	}
	return false
}

// OpenFileArgs are open_file's inputs.
type OpenFileArgs struct {
	Path string `json:"path" jsonschema:"The file to show: an absolute path, or one relative to the project root"`
	Line int    `json:"line,omitempty" jsonschema:"The line to show, counting from 1"`
}

// CloseWindowArgs are close_window's inputs.
type CloseWindowArgs struct {
	Window int `json:"window" jsonschema:"The window's id, from list_windows or open_file"`
}

// ListWindowsArgs are list_windows' inputs: none.
type ListWindowsArgs struct{}

// EditArgs are edit_file's inputs, the same as Claude Code's built-in Edit.
type EditArgs struct {
	FilePath   string `json:"file_path" jsonschema:"The absolute path to the file to modify"`
	OldString  string `json:"old_string" jsonschema:"The text to replace"`
	NewString  string `json:"new_string" jsonschema:"The text to replace it with (must be different from old_string)"`
	ReplaceAll bool   `json:"replace_all,omitempty" jsonschema:"Replace all occurrences of old_string (default false)"`
}

// WriteArgs are write_file's inputs, the same as Claude Code's built-in Write.
type WriteArgs struct {
	FilePath string `json:"file_path" jsonschema:"The absolute path to the file to write (must be absolute, not relative)"`
	Content  string `json:"content" jsonschema:"The content to write to the file"`
}

// editResult is the daemon's answer to helper/edit.
type editResult struct {
	Text    string `json:"text"`
	IsError bool   `json:"isError"`
}

// Run serves MCP on stdin and stdout for the session sessionID until Claude
// Code closes stdin.
func Run(ctx context.Context, socketPath, sessionID string, log *slog.Logger) error {
	nc, err := net.Dial("unix", socketPath)
	if err != nil {
		return fmt.Errorf("cannot reach claude-paird at %s: %w", socketPath, err)
	}
	refuse := func(context.Context, *rpc.Conn, string, json.RawMessage) (any, error) {
		return nil, rpc.Errorf(protocol.MethodNotFound, "the MCP helper takes no requests")
	}
	conn := rpc.New(0, nc, refuse, nil, log)
	go conn.Serve()
	defer conn.Close()

	if _, err := conn.Call(ctx, "initialize", map[string]any{
		"protocolVersion": protocol.Version,
		"clientInfo":      map[string]string{"name": "claude-paird-mcp", "version": version.Version},
		"capabilities":    map[string]any{"role": "mcp-helper", "sessionId": sessionID},
	}); err != nil {
		return fmt.Errorf("claude-paird refused the helper: %w", err)
	}

	server := mcp.NewServer(&mcp.Implementation{Name: ServerName, Version: version.Version}, nil)
	mcp.AddTool(server, &mcp.Tool{
		Name:        PermissionTool,
		Description: "Internal to claude-pair: answers Claude Code's permission prompts. Never call it yourself.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in map[string]any) (*mcp.CallToolResult, any, error) {
		answer, err := conn.Call(ctx, "helper/permission", map[string]any{
			"sessionId": sessionID,
			"toolName":  in["tool_name"],
			"input":     in["input"],
			"toolUseId": in["tool_use_id"],
		})
		if err != nil {
			log.Warn("permission request failed", "error", err)
			answer, _ = json.Marshal(map[string]string{
				"behavior": "deny",
				"message":  "claude-pair could not ask the user (" + err.Error() + "), so it denied this.",
			})
		}
		// Claude Code reads exactly one text block holding the decision.
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(answer)}}}, nil, nil
	})
	relay := func(ctx context.Context, params map[string]any) (*mcp.CallToolResult, any, error) {
		params["sessionId"] = sessionID
		raw, err := conn.Call(ctx, "helper/edit", params)
		var r editResult
		if err == nil {
			err = json.Unmarshal(raw, &r)
		}
		if err != nil {
			r = editResult{Text: "The edit was not made: claude-pair could not reach Emacs (" + err.Error() + ").", IsError: true}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: r.Text}}, IsError: r.IsError}, nil, nil
	}
	mcp.AddTool(server, &mcp.Tool{
		Name: "edit_file",
		Description: "Performs an exact string replacement in a file, through Emacs. old_string must match the " +
			"file's current text exactly, including whitespace and indentation, and must be unique unless " +
			"replace_all is true. The user sees the change in Emacs and applies or rejects it; a rejection " +
			"comes back as an error with the user's note. Use this instead of the built-in Edit tool.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, a EditArgs) (*mcp.CallToolResult, any, error) {
		return relay(ctx, map[string]any{"kind": "edit", "filePath": a.FilePath,
			"oldString": a.OldString, "newString": a.NewString, "replaceAll": a.ReplaceAll})
	})
	mcp.AddTool(server, &mcp.Tool{
		Name: "write_file",
		Description: "Creates a file, or replaces a file's whole content, through Emacs. The user sees the " +
			"change in Emacs and applies or rejects it. Prefer edit_file for changes to existing files. " +
			"Use this instead of the built-in Write tool.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, a WriteArgs) (*mcp.CallToolResult, any, error) {
		return relay(ctx, map[string]any{"kind": "write", "filePath": a.FilePath, "content": a.Content})
	})
	emacs := func(ctx context.Context, tool string, args map[string]any) (*mcp.CallToolResult, any, error) {
		raw, err := conn.Call(ctx, "helper/emacs", map[string]any{"sessionId": sessionID, "tool": tool, "args": args})
		var r editResult
		if err == nil {
			err = json.Unmarshal(raw, &r)
		}
		if err != nil {
			r = editResult{Text: "claude-pair could not reach Emacs (" + err.Error() + ").", IsError: true}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: r.Text}}, IsError: r.IsError}, nil, nil
	}
	mcp.AddTool(server, &mcp.Tool{
		Name: "open_file",
		Description: "Shows a file in a window of the user's Emacs, optionally at a line, so the user sees what " +
			"you are talking about. Emacs keeps at most 5 windows: below that it splits one, at the limit it " +
			"reuses the window you used least recently. It never moves the user's cursor or takes over the " +
			"window the user is working in. You do not need it to read a file yourself; use it to show the " +
			"user something. Only files inside the project.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, a OpenFileArgs) (*mcp.CallToolResult, any, error) {
		args := map[string]any{"path": a.Path}
		if a.Line > 0 {
			args["line"] = a.Line
		}
		return emacs(ctx, "open_file", args)
	})
	mcp.AddTool(server, &mcp.Tool{
		Name: "close_window",
		Description: "Closes a window you opened in the user's Emacs, given its id from list_windows or " +
			"open_file. You can close only windows you opened, never the user's or the chat's, never one the " +
			"user is working in, and never below 2 windows.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, a CloseWindowArgs) (*mcp.CallToolResult, any, error) {
		return emacs(ctx, "close_window", map[string]any{"window": a.Window})
	})
	mcp.AddTool(server, &mcp.Tool{
		Name: "list_windows",
		Description: "Lists the windows of the user's Emacs: each one's id, what it shows and which lines, " +
			"the one the user is working in, and the ones you opened and may close.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ ListWindowsArgs) (*mcp.CallToolResult, any, error) {
		return emacs(ctx, "list_windows", map[string]any{})
	})
	return server.Run(ctx, &mcp.StdioTransport{})
}
