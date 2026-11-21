package session

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

var fakeClaude string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cps-bin-")
	if err != nil {
		panic(err)
	}
	fakeClaude = filepath.Join(dir, "fakeclaude")
	if out, err := exec.Command("go", "build", "-o", fakeClaude, "../testutil/fakeclaude").CombinedOutput(); err != nil {
		panic(fmt.Sprintf("building fakeclaude: %v\n%s", err, out))
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// recorder collects updates and lets a test wait for one.
type recorder struct {
	mu      sync.Mutex
	updates []Update
	idles   int
	changed chan struct{}
}

func newRecorder() *recorder { return &recorder{changed: make(chan struct{}, 1)} }

func (r *recorder) emit(u Update) {
	r.mu.Lock()
	r.updates = append(r.updates, u)
	r.mu.Unlock()
	select {
	case r.changed <- struct{}{}:
	default:
	}
}

func (r *recorder) idle() {
	r.mu.Lock()
	r.idles++
	r.mu.Unlock()
}

// waitIdles waits until OnIdle has run n times. OnIdle runs just after the
// idle update is emitted, so a test must not read the count straight away.
func (r *recorder) waitIdles(t *testing.T, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		r.mu.Lock()
		got := r.idles
		r.mu.Unlock()
		if got == n {
			return
		}
		if got > n || time.Now().After(deadline) {
			t.Fatalf("OnIdle ran %d times, want %d", got, n)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (r *recorder) snapshot() []Update {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Update(nil), r.updates...)
}

// waitFor waits until some update satisfies match, and returns it.
func (r *recorder) waitFor(t *testing.T, what string, match func(Update) bool) Update {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		for _, u := range r.snapshot() {
			if match(u) {
				return u
			}
		}
		select {
		case <-r.changed:
		case <-deadline:
			t.Fatalf("timed out waiting for %s; got %v", what, r.snapshot())
		}
	}
}

func (r *recorder) waitIdle(t *testing.T, after int) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		n := 0
		for _, u := range r.snapshot() {
			if u["kind"] == "status" && u["state"] == "idle" {
				n++
			}
		}
		if n > after {
			return
		}
		select {
		case <-r.changed:
		case <-deadline:
			t.Fatalf("timed out waiting for idle number %d; got %v", after+1, r.kinds())
		}
	}
}

func (r *recorder) text() string {
	var b strings.Builder
	for _, u := range r.snapshot() {
		if u["kind"] == "text" {
			b.WriteString(u["delta"].(string))
		}
	}
	return b.String()
}

func (r *recorder) kinds() []string {
	var out []string
	for _, u := range r.snapshot() {
		k := u["kind"].(string)
		if k == "status" {
			k += ":" + u["state"].(string)
		}
		out = append(out, k)
	}
	return out
}

func newSession(t *testing.T, r *recorder) (*Session, string) {
	t.Helper()
	cwd := t.TempDir()
	s := New(Options{ID: "sess-123", Cwd: cwd, ClaudePath: fakeClaude, Emit: r.emit, OnIdle: r.idle})
	t.Cleanup(s.Close)
	return s, cwd
}

func TestHelloStreamsTextInOrder(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	if err := s.Prompt("script:hello"); err != nil {
		t.Fatal(err)
	}
	r.waitIdle(t, 0)
	if got := r.text(); got != "Hello wörld 🌍" {
		t.Fatalf("text %q", got)
	}
	want := "status:starting status:running init status:requesting text text text result status:idle"
	if got := strings.Join(r.kinds(), " "); got != want {
		t.Fatalf("kinds\n got %s\nwant %s", got, want)
	}
	init := r.waitFor(t, "init", func(u Update) bool { return u["kind"] == "init" })
	if init["model"] != "claude-fake-1" || init["claudeVersion"] != "2.1.327" {
		t.Fatalf("init %v", init)
	}
	r.waitIdles(t, 1)
}

func TestTextThatDidNotStreamStillArrives(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:nostream")
	r.waitIdle(t, 0)
	if got := r.text(); got != "Not streamed." {
		t.Fatalf("text %q", got)
	}
}

func TestToolsTodosAndDenials(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:tools")
	r.waitIdle(t, 0)

	var tools []string
	for _, u := range r.snapshot() {
		if u["kind"] == "tool" {
			tools = append(tools, fmt.Sprintf("%s|%s", u["status"], u["title"]))
		}
	}
	want := []string{
		"started|Read README.md", "done|Read README.md",
		"started|TodoWrite todo list", "done|TodoWrite todo list",
		"started|Bash rm -rf build …", "error|Bash rm -rf build …",
	}
	if strings.Join(tools, "\n") != strings.Join(want, "\n") {
		t.Fatalf("tools\n%s", strings.Join(tools, "\n"))
	}
	done := r.waitFor(t, "Read done", func(u Update) bool { return u["kind"] == "tool" && u["status"] == "done" })
	if ms := done["durationMs"].(int64); ms < 25 {
		t.Fatalf("durationMs %d, want at least the fake's 30 ms pause", ms)
	}
	todo := r.waitFor(t, "todo", func(u Update) bool { return u["kind"] == "todo" })
	items := todo["items"].([]map[string]any)
	if len(items) != 2 || items[0]["content"] != "Read the README" || items[1]["status"] != "in_progress" {
		t.Fatalf("todo %v", items)
	}
	result := r.waitFor(t, "result", func(u Update) bool { return u["kind"] == "result" })
	if denied := result["permissionDenials"].([]string); len(denied) != 1 || denied[0] != "Bash" {
		t.Fatalf("denials %v", result["permissionDenials"])
	}
	if r.text() != "Looking.Done." {
		t.Fatalf("text %q", r.text())
	}
}

func TestSubagentEventsAreLeftOut(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:subagent")
	r.waitIdle(t, 0)
	if got := r.text(); got != "Main." {
		t.Fatalf("text %q; subagent text must not show", got)
	}
	r.waitFor(t, "Task tool", func(u Update) bool { return u["kind"] == "tool" && u["title"] == "Task Look around" })
}

func TestFirstStartUsesSessionIDAndSafeFlags(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:args")
	r.waitIdle(t, 0)
	args := r.text()
	for _, want := range []string{
		"--session-id sess-123", "--input-format stream-json", "--output-format stream-json",
		"--include-partial-messages", "--permission-mode default", "--permission-prompts none",
		"--disallowedTools Edit,Write,NotebookEdit",
	} {
		if !strings.Contains(args, want) {
			t.Errorf("args %q lack %q", args, want)
		}
	}
	if strings.Contains(args, "--resume") {
		t.Errorf("first start must not resume: %q", args)
	}
}

func TestHelperFlags(t *testing.T) {
	s := New(Options{ID: "abc", Cwd: "/p", ClaudePath: "/c",
		HelperCommand: []string{"/bin/claude-paird", "mcp", "--socket", "/run/d.sock", "--session", "abc"}})
	args := strings.Join(s.Args(false), " ")
	for _, want := range []string{
		`--mcp-config {"mcpServers":{"emacs":{"args":["mcp","--socket","/run/d.sock","--session","abc"],"command":"/bin/claude-paird","timeout":86400000,"type":"stdio"}}}`,
		"--permission-prompt-tool mcp__emacs__permission",
		"--allowedTools mcp__emacs__edit_file,mcp__emacs__write_file,mcp__emacs__open_file,mcp__emacs__close_window,mcp__emacs__list_windows,mcp__emacs__diagnostics,mcp__emacs__xref,mcp__emacs__imenu,mcp__emacs__selection",
		"--append-system-prompt " + EditingPrompt,
	} {
		if !strings.Contains(args, want) {
			t.Errorf("args %q lack %q", args, want)
		}
	}
	if strings.Contains(args, "--permission-prompts") {
		t.Errorf("with a helper, prompts must reach it: %q", args)
	}
}

func TestPromptWhileBusyFails(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:slow:100")
	if err := s.Prompt("again"); !errors.Is(err, ErrBusy) {
		t.Fatalf("got %v, want ErrBusy", err)
	}
	if !s.Busy() {
		t.Fatal("Busy() should be true")
	}
}

func TestCancelThenResume(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:slow")
	r.waitFor(t, "some text", func(u Update) bool { return u["kind"] == "text" })
	if !s.Cancel() {
		t.Fatal("Cancel returned false during a turn")
	}
	r.waitIdle(t, 0)
	result := r.waitFor(t, "result", func(u Update) bool { return u["kind"] == "result" })
	if result["cancelled"] != true || result["isError"] != false {
		t.Fatalf("result %v, want cancelled and not an error", result)
	}
	for _, u := range r.snapshot() {
		if u["kind"] == "error" {
			t.Fatalf("a cancel is not an error: %v", u)
		}
	}
	if s.Cancel() {
		t.Fatal("Cancel returned true with nothing running")
	}

	before := len(r.snapshot())
	if err := s.Prompt("script:args"); err != nil {
		t.Fatal(err)
	}
	r.waitIdle(t, 1)
	var args string
	for _, u := range r.snapshot()[before:] {
		if u["kind"] == "text" {
			args += u["delta"].(string)
		}
	}
	if !strings.Contains(args, "--resume sess-123") || strings.Contains(args, "--session-id") {
		t.Fatalf("restart args %q, want --resume", args)
	}
}

func TestCrashIsReportedAndTheNextPromptResumes(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:crash")
	r.waitIdle(t, 0)
	e := r.waitFor(t, "error", func(u Update) bool { return u["kind"] == "error" })
	if e["exitCode"] != 3 || !strings.Contains(e["stderr"].(string), "fatal: something broke") {
		t.Fatalf("error %v", e)
	}
	r.waitIdles(t, 1)
	before := len(r.snapshot())
	if err := s.Prompt("script:args"); err != nil {
		t.Fatalf("prompt after a crash: %v", err)
	}
	r.waitIdle(t, 1)
	var args string
	for _, u := range r.snapshot()[before:] {
		if u["kind"] == "text" {
			args += u["delta"].(string)
		}
	}
	if !strings.Contains(args, "--resume sess-123") {
		t.Fatalf("restart args %q", args)
	}
}

func TestErrorResult(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:fail")
	r.waitIdle(t, 0)
	result := r.waitFor(t, "result", func(u Update) bool { return u["kind"] == "result" })
	if result["isError"] != true || result["subtype"] != "error_max_turns" ||
		result["message"] != "Reached the maximum number of turns" {
		t.Fatalf("result %v", result)
	}
}

func TestCostPerTurnAcrossRestarts(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	costs := func() (turns []float64, session float64) {
		for _, u := range r.snapshot() {
			if u["kind"] == "result" {
				if c, ok := u["costUsd"].(float64); ok {
					turns = append(turns, c)
					session = u["sessionCostUsd"].(float64)
				}
			}
		}
		return
	}
	for i, prompt := range []string{"script:hello", "script:hello", "script:crash", "script:hello"} {
		// After the crash, the next process starts its cost at zero again.
		if err := s.Prompt(prompt); err != nil {
			t.Fatalf("prompt %d: %v", i, err)
		}
		r.waitIdle(t, i)
	}
	turns, session := costs()
	if len(turns) != 3 {
		t.Fatalf("turn costs %v", turns)
	}
	for _, c := range turns {
		if c < 0.0099 || c > 0.0101 {
			t.Fatalf("turn costs %v, want 0.01 each", turns)
		}
	}
	if session < 0.0299 || session > 0.0301 || s.TotalCostUSD() != session {
		t.Fatalf("session cost %v", session)
	}
}

func TestCloseStopsClaude(t *testing.T) {
	r := newRecorder()
	s, _ := newSession(t, r)
	s.Prompt("script:slow")
	r.waitFor(t, "some text", func(u Update) bool { return u["kind"] == "text" })
	s.mu.Lock()
	p := s.proc
	s.mu.Unlock()
	s.Close()
	select {
	case <-p.done:
	default:
		t.Fatal("Close returned before claude exited")
	}
	if err := s.Prompt("hi"); !errors.Is(err, ErrClosed) {
		t.Fatalf("got %v, want ErrClosed", err)
	}
}

func TestCheckClaude(t *testing.T) {
	if v, err := CheckClaude(fakeClaude); err != nil || v != "2.1.327" {
		t.Fatalf("got %q, %v", v, err)
	}
	var unavailable *UnavailableError
	for name, path := range map[string]string{
		"empty":     "",
		"relative":  "claude",
		"missing":   "/nonexistent/claude",
		"directory": t.TempDir(),
	} {
		if _, err := CheckClaude(path); !errors.As(err, &unavailable) {
			t.Errorf("%s: got %v, want UnavailableError", name, err)
		}
	}
}

func TestCheckClaudeTooOld(t *testing.T) {
	old := filepath.Join(t.TempDir(), "claude")
	data, _ := os.ReadFile(fakeClaude)
	os.WriteFile(old, data, 0o755)
	t.Setenv("FAKE_CLAUDE_VERSION", "2.0.9")
	_, err := CheckClaude(old)
	if err == nil || !strings.Contains(err.Error(), "2.0.9 is too old") || !strings.Contains(err.Error(), MinClaudeVersion) {
		t.Fatalf("got %v", err)
	}
}

func TestToolTitles(t *testing.T) {
	cwd := "/work/proj"
	cases := []struct {
		name  string
		input map[string]any
		want  string
	}{
		{"Read", map[string]any{"file_path": "/work/proj/src/a.go"}, "Read src/a.go"},
		{"Read", map[string]any{"file_path": "/etc/hosts"}, "Read /etc/hosts"},
		{"Bash", map[string]any{"command": "make test"}, "Bash make test"},
		{"Grep", map[string]any{"pattern": "TODO", "path": "/work/proj/lisp"}, "Grep TODO in lisp"},
		{"WebFetch", map[string]any{"url": "https://example.com"}, "WebFetch https://example.com"},
		{"mcp__github__create_issue", map[string]any{"title": "x"}, "github: create_issue"},
		{"mcp__emacs__open_file", map[string]any{"path": "/work/proj/src/a.go", "line": 12.0}, "Show src/a.go:12"},
		{"mcp__emacs__open_file", map[string]any{"path": "src/a.go"}, "Show src/a.go"},
		{"mcp__emacs__close_window", map[string]any{"window": 3.0}, "Close window 3"},
		{"mcp__emacs__list_windows", map[string]any{}, "List windows"},
		{"mcp__emacs__diagnostics", map[string]any{"path": "/work/proj/src/a.go"}, "Diagnostics src/a.go"},
		{"mcp__emacs__diagnostics", map[string]any{}, "Diagnostics of open files"},
		{"mcp__emacs__xref", map[string]any{"symbol": "area", "kind": "references"}, "Xref references of area"},
		{"mcp__emacs__xref", map[string]any{"symbol": "area"}, "Xref definitions of area"},
		{"mcp__emacs__imenu", map[string]any{"path": "/work/proj/geo.py"}, "Outline geo.py"},
		{"mcp__emacs__selection", map[string]any{}, "Your selection in Emacs"},
		{"Mystery", map[string]any{}, "Mystery"},
		{"ToolSearch", map[string]any{"query": "select:mcp__emacs__edit_file"}, "ToolSearch select:mcp__emacs__edit_file"},
		{"mcp__emacs__edit_file", map[string]any{"file_path": "/work/proj/a.txt"}, "Edit a.txt"},
		{"mcp__emacs__write_file", map[string]any{"file_path": "/work/proj/docs/b.md"}, "Write docs/b.md"},
		{"Bash", map[string]any{"command": strings.Repeat("x", 100)}, "Bash " + strings.Repeat("x", 79) + "…"},
	}
	for _, c := range cases {
		if got := ToolTitle(c.name, c.input, cwd); got != c.want {
			t.Errorf("ToolTitle(%s, %v) = %q, want %q", c.name, c.input, got, c.want)
		}
	}
}

func TestInstructionsGoIntoTheSystemPrompt(t *testing.T) {
	s := New(Options{ID: "abc", Cwd: "/p", ClaudePath: "/c", Instructions: "  Use simple English.  ",
		HelperCommand: []string{"/bin/claude-paird", "mcp"}})
	args := s.Args(false)
	var prompt string
	for i, a := range args {
		if a == "--append-system-prompt" {
			if prompt != "" {
				t.Fatal("--append-system-prompt given twice")
			}
			prompt = args[i+1]
		}
	}
	if prompt != EditingPrompt+"\n\nThe user's instructions for every answer: Use simple English." {
		t.Fatalf("system prompt %q", prompt)
	}
	// Without the helper, the instructions still go in.
	s = New(Options{ID: "abc", Cwd: "/p", ClaudePath: "/c", Instructions: "Be brief."})
	if got := strings.Join(s.Args(false), " "); !strings.Contains(got, "--append-system-prompt The user's instructions for every answer: Be brief.") {
		t.Fatalf("args %q", got)
	}
	// Neither: no flag at all.
	s = New(Options{ID: "abc", Cwd: "/p", ClaudePath: "/c"})
	if got := strings.Join(s.Args(false), " "); strings.Contains(got, "--append-system-prompt") {
		t.Fatalf("args %q", got)
	}
}
