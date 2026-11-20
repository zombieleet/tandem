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

// PermissionToolName is the name Claude Code knows the permission tool by.
const PermissionToolName = "mcp__" + ServerName + "__" + PermissionTool

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
	return server.Run(ctx, &mcp.StdioTransport{})
}
