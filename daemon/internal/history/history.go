// Package history reads the conversations Claude Code keeps on disk, so a
// chat can be listed, reopened and drawn again.
//
// Claude Code writes one JSON Lines file per conversation, named after its
// session ID, under <config dir>/projects/<the project path with every
// character other than a letter or digit turned into "-">/.
package history

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Chat describes one conversation.
type Chat struct {
	SessionID string    `json:"sessionId"`
	Title     string    `json:"title"`
	Modified  time.Time `json:"modified"`
	Prompts   int       `json:"prompts"`
	CostUSD   float64   `json:"costUsd"`
}

// Entry is one piece of a conversation, in order.
type Entry struct {
	// Kind is "user" (a message from the user), "text" (Claude's words) or
	// "tool" (a tool Claude called; Name and Input say which).
	Kind  string         `json:"kind"`
	Text  string         `json:"text,omitempty"`
	Name  string         `json:"-"`
	Input map[string]any `json:"-"`
	// Title describes a tool call, filled in by the caller.
	Title string `json:"title,omitempty"`
	// Error is true for a tool call that failed.
	Error bool   `json:"error,omitempty"`
	id    string // tool_use id, to match its result
}

// ErrNoChat is returned for a session with no conversation on disk.
var ErrNoChat = errors.New("no conversation with that ID in this project")

var sessionIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ValidID reports whether id looks like a session ID, and so is safe as a
// file name.
func ValidID(id string) bool { return sessionIDPattern.MatchString(id) }

// ConfigDir returns Claude Code's directory: CLAUDE_CONFIG_DIR from env when
// set there (a nil value removes it), else from the environment, else
// ~/.claude.
func ConfigDir(env map[string]*string) string {
	if v, ok := env["CLAUDE_CONFIG_DIR"]; ok {
		if v != nil && *v != "" {
			return *v
		}
	} else if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude")
}

// ProjectDir returns where Claude Code keeps the conversations about cwd.
func ProjectDir(configDir, cwd string) string {
	var b strings.Builder
	for _, r := range cwd {
		if r < 128 && (r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return filepath.Join(configDir, "projects", b.String())
}

// record is the part of a transcript line this package reads.
type record struct {
	Type        string  `json:"type"`
	Cwd         string  `json:"cwd"`
	IsSidechain bool    `json:"isSidechain"`
	IsMeta      bool    `json:"isMeta"`
	AITitle     string  `json:"aiTitle"`
	CustomTitle string  `json:"customTitle"`
	TotalCost   float64 `json:"totalCostUSD"`
	Message     struct {
		ID      string          `json:"id"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type block struct {
	Type    string          `json:"type"`
	Text    string          `json:"text"`
	ID      string          `json:"id"`
	Name    string          `json:"name"`
	Input   map[string]any  `json:"input"`
	ToolUse string          `json:"tool_use_id"`
	IsError bool            `json:"is_error"`
	Content json.RawMessage `json:"content"`
}

// interesting holds the record types worth decoding; others, some of them
// large, are skipped without parsing.
var interesting = [][]byte{
	[]byte(`"type":"user"`), []byte(`"type":"assistant"`), []byte(`"type":"ai-title"`),
	[]byte(`"type":"custom-title"`), []byte(`"type":"cost-state"`),
}

// eachRecord calls fn for every interesting record of the file at path.
func eachRecord(path string, fn func(*record)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 1<<16)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 && wanted(line) {
			var rec record
			if json.Unmarshal(line, &rec) == nil {
				fn(&rec)
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func wanted(line []byte) bool {
	for _, t := range interesting {
		if bytes.Contains(line, t) {
			return true
		}
	}
	return false
}

// userText returns the words of a user record, or "" for a tool result or
// a message Claude Code added itself.
func userText(rec *record) string {
	if rec.IsMeta || rec.IsSidechain {
		return ""
	}
	var s string
	if json.Unmarshal(rec.Message.Content, &s) == nil {
		return s
	}
	var blocks []block
	if json.Unmarshal(rec.Message.Content, &blocks) != nil {
		return ""
	}
	var parts []string
	for _, b := range blocks {
		switch b.Type {
		case "tool_result":
			return ""
		case "text":
			parts = append(parts, b.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// added reports whether a user message was written by Claude Code, not the
// user: command output, interruptions and the like.
func added(text string) bool {
	t := strings.TrimSpace(text)
	return t == "" || strings.HasPrefix(t, "<") || strings.HasPrefix(t, "[Request interrupted")
}

// List returns the conversations about cwd, newest first, at most limit.
func List(configDir, cwd string, limit int) ([]Chat, error) {
	dir := ProjectDir(configDir, cwd)
	files, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return []Chat{}, nil
	}
	if err != nil {
		return nil, err
	}
	type file struct {
		id  string
		mod time.Time
	}
	var all []file
	for _, f := range files {
		id, ok := strings.CutSuffix(f.Name(), ".jsonl")
		if !ok || f.IsDir() || !ValidID(id) {
			continue
		}
		if info, err := f.Info(); err == nil {
			all = append(all, file{id, info.ModTime()})
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].mod.After(all[j].mod) })
	chats := []Chat{}
	for _, f := range all {
		if len(chats) >= limit {
			break
		}
		c := Chat{SessionID: f.id, Modified: f.mod}
		var first, aiTitle, custom string
		foreign := false
		_ = eachRecord(filepath.Join(dir, f.id+".jsonl"), func(rec *record) {
			switch rec.Type {
			case "user":
				if rec.Cwd != "" && rec.Cwd != cwd {
					foreign = true
				}
				if t := userText(rec); !added(t) {
					c.Prompts++
					if first == "" {
						first = t
					}
				}
			case "ai-title":
				aiTitle = rec.AITitle
			case "custom-title":
				custom = rec.CustomTitle
			case "cost-state":
				c.CostUSD = rec.TotalCost
			}
		})
		if c.Prompts == 0 || foreign {
			continue
		}
		c.Title = firstNonEmpty(custom, aiTitle, oneLine(first, 80))
		chats = append(chats, c)
	}
	return chats, nil
}

// Read returns the conversation with id about cwd. Tool calls carry their
// name and input; Title is left for the caller.
func Read(configDir, cwd, id string) ([]Entry, error) {
	if !ValidID(id) {
		return nil, ErrNoChat
	}
	path := filepath.Join(ProjectDir(configDir, cwd), id+".jsonl")
	if _, err := os.Stat(path); err != nil {
		return nil, ErrNoChat
	}
	entries := []Entry{}
	tools := map[string]int{}
	lastMsg := ""
	err := eachRecord(path, func(rec *record) {
		if rec.IsSidechain {
			return
		}
		switch rec.Type {
		case "user":
			if t := userText(rec); !added(t) {
				entries = append(entries, Entry{Kind: "user", Text: t})
				lastMsg = ""
				return
			}
			var blocks []block
			if json.Unmarshal(rec.Message.Content, &blocks) == nil {
				for _, b := range blocks {
					if i, ok := tools[b.ToolUse]; ok && b.Type == "tool_result" && b.IsError {
						entries[i].Error = true
					}
				}
			}
		case "assistant":
			var blocks []block
			if json.Unmarshal(rec.Message.Content, &blocks) != nil {
				return
			}
			for _, b := range blocks {
				switch b.Type {
				case "text":
					if strings.TrimSpace(b.Text) == "" {
						continue
					}
					// Claude Code writes each block of a message as its own
					// record; text of one message is joined.
					if n := len(entries); n > 0 && entries[n-1].Kind == "text" && lastMsg == rec.Message.ID && rec.Message.ID != "" {
						entries[n-1].Text += b.Text
					} else {
						entries = append(entries, Entry{Kind: "text", Text: b.Text})
					}
				case "tool_use":
					tools[b.ID] = len(entries)
					entries = append(entries, Entry{Kind: "tool", Name: b.Name, Input: b.Input, id: b.ID})
				}
			}
			lastMsg = rec.Message.ID
		}
	})
	return entries, err
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func oneLine(s string, max int) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if r := []rune(s); len(r) > max {
		s = string(r[:max-1]) + "…"
	}
	return s
}
