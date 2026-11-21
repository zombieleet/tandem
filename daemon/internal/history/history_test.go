package history

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const idA = "11111111-2222-4333-8444-555555555555"
const idB = "66666666-7777-4888-9999-000000000000"

func write(t *testing.T, dir, id string, lines ...string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, id+".jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProjectDir(t *testing.T) {
	got := ProjectDir("/c", "/home/v/personal-projects/my.app_1")
	if got != "/c/projects/-home-v-personal-projects-my-app-1" {
		t.Fatalf("got %s", got)
	}
}

func TestConfigDir(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/from/env")
	if ConfigDir(nil) != "/from/env" {
		t.Fatal("environment ignored")
	}
	v := "/from/session"
	if ConfigDir(map[string]*string{"CLAUDE_CONFIG_DIR": &v}) != v {
		t.Fatal("session env ignored")
	}
	if ConfigDir(map[string]*string{"CLAUDE_CONFIG_DIR": nil}) == "/from/env" {
		t.Fatal("a removed variable still used")
	}
}

func TestListAndRead(t *testing.T) {
	cfg := t.TempDir()
	cwd := "/work/geo"
	dir := ProjectDir(cfg, cwd)
	old := write(t, dir, idA,
		`{"type":"user","cwd":"/work/geo","message":{"role":"user","content":"where is area used?\nsecond line"}}`,
		`{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"hm"}]}}`,
		`{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -rn area ."}}]}}`,
		`{"type":"user","cwd":"/work/geo","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"geo.py:4","is_error":true}]}}`,
		`{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"It is used "}]}}`,
		`{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"in `+"`main`"+`."}]}}`,
		`{"type":"user","cwd":"/work/geo","isSidechain":true,"message":{"content":"a subagent's prompt"}}`,
		`{"type":"user","cwd":"/work/geo","isMeta":true,"message":{"content":"Caveat: added by Claude Code"}}`,
		`{"type":"user","cwd":"/work/geo","message":{"content":"<command-name>/model</command-name>"}}`,
		`{"type":"cost-state","totalCostUSD":0.25}`,
		`{"type":"api-request-blob","content":[{"type":"text","text":"\"type\":\"user\" not a record"}]}`,
		`not json`,
		`{"type":"user","cwd":"/work/geo","message":{"content":[{"type":"text","text":"thanks"}]}}`,
	)
	write(t, dir, idB,
		`{"type":"user","cwd":"/work/geo","message":{"content":"newer chat"}}`,
		`{"type":"ai-title","aiTitle":"A newer chat"}`,
	)
	// Only Claude Code's own records: no prompt, not listed.
	write(t, dir, "99999999-7777-4888-9999-000000000000", `{"type":"queue-operation"}`)
	// Not a session file.
	write(t, dir, "notes")
	past := time.Now().Add(-time.Hour)
	_ = os.Chtimes(old, past, past)

	chats, err := List(cfg, cwd, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 2 || chats[0].SessionID != idB || chats[1].SessionID != idA {
		t.Fatalf("chats %+v", chats)
	}
	if chats[0].Title != "A newer chat" || chats[1].Title != "where is area used?" ||
		chats[1].Prompts != 2 || chats[1].CostUSD != 0.25 {
		t.Fatalf("chats %+v", chats)
	}
	if one, _ := List(cfg, cwd, 1); len(one) != 1 {
		t.Fatalf("limit ignored: %+v", one)
	}
	if none, err := List(cfg, "/elsewhere", 10); err != nil || len(none) != 0 {
		t.Fatalf("other project: %v %v", none, err)
	}

	entries, err := Read(cfg, cwd, idA)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range entries {
		s := e.Kind + ":" + e.Text + e.Name
		if e.Error {
			s += "!"
		}
		got = append(got, s)
	}
	want := []string{"user:where is area used?\nsecond line", "tool:Bash!", "text:It is used in `main`.", "user:thanks"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("entries\n got %q\nwant %q", got, want)
	}
	if entries[1].Input["command"] != "grep -rn area ." {
		t.Fatalf("tool input %v", entries[1].Input)
	}
	if _, err := Read(cfg, cwd, "../../etc/passwd"); err != ErrNoChat {
		t.Fatalf("bad id: %v", err)
	}
	if _, err := Read(cfg, cwd, "aaaaaaaa-2222-4333-8444-555555555555"); err != ErrNoChat {
		t.Fatalf("missing: %v", err)
	}
}

func TestAChatFromAnotherFolderWithTheSameDirectoryIsLeftOut(t *testing.T) {
	cfg := t.TempDir()
	// "/work/a.b" and "/work/a-b" share a directory.
	write(t, ProjectDir(cfg, "/work/a.b"), idA, `{"type":"user","cwd":"/work/a-b","message":{"content":"hi"}}`)
	if chats, _ := List(cfg, "/work/a.b", 10); len(chats) != 0 {
		t.Fatalf("chats %+v", chats)
	}
}
