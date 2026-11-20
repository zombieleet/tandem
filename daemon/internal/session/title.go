package session

import (
	"path/filepath"
	"strings"
)

// ToolTitle is the one-line description Emacs shows for a tool call, such as
// "Read src/api.ts" or "Bash make test".
func ToolTitle(name string, input map[string]any, cwd string) string {
	str := func(key string) string {
		v, _ := input[key].(string)
		return v
	}
	var detail string
	switch name {
	case "Read", "Write", "Edit", "NotebookEdit":
		detail = relative(str("file_path"), cwd)
	case "Bash":
		detail = str("command")
	case "Glob":
		detail = str("pattern")
		if p := str("path"); p != "" {
			detail += " in " + relative(p, cwd)
		}
	case "Grep":
		detail = str("pattern")
		if p := str("path"); p != "" {
			detail += " in " + relative(p, cwd)
		}
	case "WebFetch":
		detail = str("url")
	case "WebSearch":
		detail = str("query")
	case "Task", "Agent":
		detail = str("description")
	case "TodoWrite":
		detail = "todo list"
	case "ToolSearch":
		detail = str("query")
	case "mcp__emacs__edit_file":
		return "Edit " + relative(str("file_path"), cwd)
	case "mcp__emacs__write_file":
		return "Write " + relative(str("file_path"), cwd)
	default:
		if server, tool, ok := strings.Cut(strings.TrimPrefix(name, "mcp__"), "__"); ok && strings.HasPrefix(name, "mcp__") {
			return server + ": " + tool
		}
	}
	detail = firstLine(detail, 80)
	if detail == "" {
		return name
	}
	return name + " " + detail
}

func relative(path, cwd string) string {
	if path == "" || cwd == "" || !filepath.IsAbs(path) {
		return path
	}
	rel, err := filepath.Rel(cwd, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return path
	}
	return rel
}

func firstLine(s string, max int) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i] + " …"
	}
	if r := []rune(s); len(r) > max {
		s = string(r[:max-1]) + "…"
	}
	return s
}
