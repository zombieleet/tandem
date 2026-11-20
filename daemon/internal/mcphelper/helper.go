// Package mcphelper is "claude-paird mcp": an MCP server that Claude Code
// starts over stdio. It answers Claude Code's permission prompts, and later
// the Emacs tools, by relaying each call to the daemon over its socket.
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
)

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
	return server.Run(ctx, &mcp.StdioTransport{})
}
