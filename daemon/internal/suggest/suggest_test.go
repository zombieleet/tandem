package suggest

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/victory/tandem/daemon/internal/testutil"
)

var fakeClaude string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "suggest-test-")
	if err != nil {
		panic(err)
	}
	fakeClaude, err = testutil.Binary(dir, "fakeclaude", "github.com/victory/tandem/daemon/internal/testutil/fakeclaude")
	if err != nil {
		panic(err)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func newSuggester(t *testing.T) (*Suggester, Config, string) {
	t.Helper()
	log := filepath.Join(t.TempDir(), "args.log")
	s := New(Options{Dir: t.TempDir()})
	t.Cleanup(s.Close)
	v := log
	return s, Config{ClaudePath: fakeClaude, Env: map[string]*string{"FAKE_CLAUDE_ARGS_LOG": &v}}, log
}

func TestCompleteStreamsAndCleans(t *testing.T) {
	s, cfg, log := newSuggester(t)
	var mu sync.Mutex
	var pieces []string
	text, err := s.Complete(context.Background(), cfg, Request{
		File: "geo.py", Language: "python",
		Prefix: "def circumference(r):\n    # fake-suggest:    return 2 * math.pi * r\\n\n    ",
		Suffix: "\n",
	}, func(t string) { mu.Lock(); pieces = append(pieces, t); mu.Unlock() })
	if err != nil {
		t.Fatal(err)
	}
	// The indentation the line has already is not repeated.
	if text != "return 2 * math.pi * r" {
		t.Fatalf("got %q", text)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(pieces) != 2 || !strings.HasPrefix(text, pieces[0]) {
		t.Fatalf("pieces %q", pieces)
	}
	args, _ := os.ReadFile(log)
	for _, want := range []string{"--model " + DefaultModel, "--tools  ", "--effort low", "--no-session-persistence"} {
		if !strings.Contains(string(args), want) {
			t.Errorf("args lack %q:\n%s", want, args)
		}
	}
}

func TestSpareIsUsedAndReplaced(t *testing.T) {
	s, cfg, log := newSuggester(t)
	req := Request{Prefix: "x = fake-suggest:1<", Suffix: ""}
	if _, err := s.Complete(context.Background(), cfg, req, nil); err != nil {
		t.Fatal(err)
	}
	// The first request started two: its own and a spare.
	waitLines(t, log, 2)
	s.mu.Lock()
	spare := s.spare
	s.mu.Unlock()
	if spare == nil {
		t.Fatal("no spare after a request")
	}
	if _, err := s.Complete(context.Background(), cfg, req, nil); err != nil {
		t.Fatal(err)
	}
	// The second used the spare and started one more.
	waitLines(t, log, 3)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.spare == nil || s.spare == spare {
		t.Fatal("the spare was not used and replaced")
	}
}

func TestSpareForAnotherModelIsNotUsed(t *testing.T) {
	s, cfg, log := newSuggester(t)
	req := Request{Prefix: "fake-suggest:1<"}
	if _, err := s.Complete(context.Background(), cfg, req, nil); err != nil {
		t.Fatal(err)
	}
	cfg.Model = "claude-other"
	if _, err := s.Complete(context.Background(), cfg, req, nil); err != nil {
		t.Fatal(err)
	}
	// The Haiku spare is stopped, maybe before it even logs its start; the
	// request and the next spare both run the other model.
	deadline := time.Now().Add(5 * time.Second)
	for {
		args, _ := os.ReadFile(log)
		if strings.Count(string(args), "--model claude-other") == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("args:\n%s", args)
		}
		time.Sleep(20 * time.Millisecond)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.spare == nil || s.spare.key != cfg.key() {
		t.Fatal("the spare is not for the other model")
	}
}

func TestNewerRequestSupersedes(t *testing.T) {
	s, cfg, _ := newSuggester(t)
	done := make(chan error, 1)
	go func() {
		_, err := s.Complete(context.Background(), cfg, Request{Prefix: "fake-suggest:slow:old one<"}, nil)
		done <- err
	}()
	time.Sleep(300 * time.Millisecond)
	text, err := s.Complete(context.Background(), cfg, Request{Prefix: "fake-suggest:new one<"}, nil)
	if err != nil || text != "new one" {
		t.Fatalf("newer: %q %v", text, err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrSuperseded) {
			t.Fatalf("older ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the older request did not end")
	}
}

func TestCancelAndContext(t *testing.T) {
	s, cfg, _ := newSuggester(t)
	if s.Cancel() {
		t.Fatal("cancelled nothing")
	}
	done := make(chan error, 1)
	go func() {
		_, err := s.Complete(context.Background(), cfg, Request{Prefix: "fake-suggest:slow:abc<"}, nil)
		done <- err
	}()
	time.Sleep(300 * time.Millisecond)
	if !s.Cancel() {
		t.Fatal("nothing to cancel")
	}
	if err := <-done; !errors.Is(err, ErrCancelled) {
		t.Fatalf("got %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := s.Complete(ctx, cfg, Request{Prefix: "fake-suggest:slow:abc<"}, nil); !errors.Is(err, ErrCancelled) {
		t.Fatalf("context: %v", err)
	}
}

func TestUnusedSpareStops(t *testing.T) {
	s := New(Options{Dir: t.TempDir(), SpareIdle: 200 * time.Millisecond})
	defer s.Close()
	if _, err := s.Complete(context.Background(), Config{ClaudePath: fakeClaude}, Request{Prefix: "fake-suggest:1<"}, nil); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		gone := s.spare == nil
		s.mu.Unlock()
		if gone {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the spare is still there")
}

func TestMissingClaude(t *testing.T) {
	s := New(Options{Dir: t.TempDir()})
	defer s.Close()
	if _, err := s.Complete(context.Background(), Config{ClaudePath: filepath.Join(t.TempDir(), "nope")}, Request{}, nil); err == nil {
		t.Fatal("no error")
	}
}

func TestClean(t *testing.T) {
	for _, c := range []struct {
		prefix, suffix, text string
		final                bool
		want                 string
	}{
		{"def f():\n    ", "\n", "    return 1\n", true, "return 1"},
		{"x = ", "", "```python\n42\n```", true, "42"},
		{"x = ", "", "```py", false, ""},
		{"x = ", "", "```py\n4", false, "4"},
		{"print(", ")\n", "a, b)", true, "a, b"},
		{"    re", "", "    return x", true, "turn x"},
		{"y = ", "", "1 +  ", false, "1 +  "},
	} {
		got := Clean(Request{Prefix: c.prefix, Suffix: c.suffix}, c.text, c.final)
		if got != c.want {
			t.Errorf("Clean(%q, %q, %q) = %q, want %q", c.prefix, c.suffix, c.text, got, c.want)
		}
	}
	if p := (Request{File: "a.go", Language: "go", Prefix: "x", Suffix: "y"}).Prompt(); p != "File: a.go (go)\n\nx<CURSOR>y" {
		t.Errorf("prompt %q", p)
	}
}

func waitLines(t *testing.T, path string, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		b, _ := os.ReadFile(path)
		if strings.Count(string(b), "\n") >= n {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	b, _ := os.ReadFile(path)
	t.Fatalf("wanted %d starts, log:\n%s", n, b)
}
