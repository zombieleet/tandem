// Package suggest completes code at the cursor with Claude, for the grey
// suggestions Emacs shows as you type.
//
// Each suggestion runs in its own short claude process: a small model, no
// tools, no settings or MCP servers, and a system prompt of a few lines
// in place of Claude Code's own, which makes it cheap. Starting claude
// takes about a second, so a spare process is started ahead of time and
// waits for its prompt; it is stopped when suggestions have not been asked
// for in a while. A new request ends the one still running: only the
// newest place you paused at matters.
package suggest

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/zombieleet/tandem/daemon/internal/session"
)

// DefaultModel is the model suggestions use unless a request names one.
const DefaultModel = "claude-haiku-5-5"

// SystemPrompt replaces Claude Code's system prompt for suggestions.
const SystemPrompt = "You are a code completion engine inside a text editor. " +
	"The user's message is a file with <CURSOR> where the cursor is. " +
	"Reply with only the text to insert at <CURSOR> so the code continues naturally: " +
	"the rest of the statement or line, or a block of up to 15 lines when the code calls for one. " +
	"No explanation, no code fences, and never repeat text that is already before or after the cursor. " +
	"Match the file's indentation and style. If nothing sensible fits, reply with an empty message."

// ErrSuperseded ends a request when a newer one starts.
var ErrSuperseded = errors.New("a newer suggestion request replaced this one")

// ErrCancelled ends a request cancelled by Cancel.
var ErrCancelled = errors.New("the suggestion was cancelled")

// Config is how claude runs; a spare process is only used for a request
// with the same Config.
type Config struct {
	ClaudePath string
	Model      string
	Env        map[string]*string
}

func (c Config) key() string {
	b, _ := json.Marshal(c)
	return string(b)
}

// Request is the code around the cursor.
type Request struct {
	File     string // the file's name, relative to its project
	Language string // e.g. "python"
	Prefix   string // the text before the cursor
	Suffix   string // the text after the cursor
}

// Prompt returns the message claude gets for r.
func (r Request) Prompt() string {
	var b strings.Builder
	if r.File != "" {
		fmt.Fprintf(&b, "File: %s", r.File)
		if r.Language != "" {
			fmt.Fprintf(&b, " (%s)", r.Language)
		}
		b.WriteString("\n\n")
	}
	b.WriteString(r.Prefix)
	b.WriteString("<CURSOR>")
	b.WriteString(r.Suffix)
	return b.String()
}

// Options configure a Suggester.
type Options struct {
	// Dir is where claude runs: an empty directory, so no project's
	// CLAUDE.md is read.
	Dir string
	// SpareIdle is how long a spare process waits for a request before
	// it is stopped; zero means five minutes.
	SpareIdle time.Duration
	Log       *slog.Logger
}

// Suggester runs suggestions one at a time.
type Suggester struct {
	opts Options

	mu         sync.Mutex
	spare      *proc
	spareTimer *time.Timer
	current    *proc
	closed     bool
	// running counts the claude processes that have not exited yet.
	running sync.WaitGroup
}

// New returns a Suggester.
func New(opts Options) *Suggester {
	if opts.SpareIdle == 0 {
		opts.SpareIdle = 5 * time.Minute
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Suggester{opts: opts}
}

// proc is one claude process, started and waiting for its prompt.
type proc struct {
	key    string
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	out    *io.PipeReader
	lines  *bufio.Scanner
	reason error // why it was stopped early, if it was
	once   sync.Once
}

// stop ends p; a read of its output in progress ends too.
func (p *proc) stop(reason error) {
	p.once.Do(func() {
		p.reason = reason
		_ = p.cmd.Process.Kill()
		_ = p.out.Close()
	})
}

// Args returns claude's arguments for model.
func Args(model string) []string {
	return []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--verbose", "--include-partial-messages", "--model", model,
		"--no-session-persistence", "--tools", "", "--strict-mcp-config",
		"--setting-sources", "", "--system-prompt", SystemPrompt,
		"--effort", "low", "--max-turns", "1"}
}

func (s *Suggester) start(cfg Config) (*proc, error) {
	model := cfg.Model
	if model == "" {
		model = DefaultModel
	}
	cmd := exec.Command(cfg.ClaudePath, Args(model)...)
	cmd.Dir = s.opts.Dir
	if len(cfg.Env) > 0 {
		cmd.Env = session.MergeEnv(os.Environ(), cfg.Env)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	// Through an io.Pipe, so Wait can run while the output is read: the
	// reader sees all of it, then EOF; stop closes the reader.
	out, w := io.Pipe()
	cmd.Stdout = w
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("cannot start claude: %w", err)
	}
	lines := bufio.NewScanner(out)
	lines.Buffer(make([]byte, 64<<10), 16<<20)
	p := &proc{key: cfg.key(), cmd: cmd, stdin: stdin, out: out, lines: lines}
	s.running.Add(1)
	go func() {
		defer s.running.Done()
		_ = cmd.Wait()
		_ = w.Close()
	}()
	return p, nil
}

// take returns the spare process for cfg, or starts one, and starts
// the next spare. It also ends the request still running.
func (s *Suggester) take(cfg Config) (*proc, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, errors.New("the daemon is stopping")
	}
	if s.current != nil {
		s.current.stop(ErrSuperseded)
		s.current = nil
	}
	p := s.spare
	s.spare = nil
	if p != nil && p.key != cfg.key() {
		p.stop(ErrCancelled)
		p = nil
	}
	if p == nil {
		var err error
		if p, err = s.start(cfg); err != nil {
			return nil, err
		}
	}
	s.current = p
	// The next one starts now, while this one works.
	if spare, err := s.start(cfg); err == nil {
		s.spare = spare
		if s.spareTimer != nil {
			s.spareTimer.Stop()
		}
		s.spareTimer = time.AfterFunc(s.opts.SpareIdle, func() { s.dropSpare(spare) })
	} else {
		s.opts.Log.Warn("cannot start a spare claude for suggestions", "error", err)
	}
	return p, nil
}

func (s *Suggester) dropSpare(p *proc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.spare == p {
		s.spare = nil
		p.stop(ErrCancelled)
		s.opts.Log.Debug("stopped the spare claude for suggestions: unused")
	}
}

// Complete asks claude for the text to insert in r. onText gets the
// suggestion so far, cleaned, each time more of it arrives. It returns
// the whole suggestion, ErrSuperseded when a newer request ended it, or
// ErrCancelled.
func (s *Suggester) Complete(ctx context.Context, cfg Config, r Request, onText func(string)) (string, error) {
	p, err := s.take(cfg)
	if err != nil {
		return "", err
	}
	defer func() {
		s.mu.Lock()
		if s.current == p {
			s.current = nil
		}
		s.mu.Unlock()
		p.stop(nil)
	}()
	stopWatch := context.AfterFunc(ctx, func() { p.stop(ErrCancelled) })
	defer stopWatch()

	msg, _ := json.Marshal(map[string]any{"type": "user",
		"message": map[string]any{"role": "user", "content": r.Prompt()}})
	if _, err := p.stdin.Write(append(msg, '\n')); err != nil {
		return "", s.why(p, fmt.Errorf("cannot send to claude: %w", err))
	}
	_ = p.stdin.Close()

	var text strings.Builder
	for p.lines.Scan() {
		var event struct {
			Type    string `json:"type"`
			Subtype string `json:"subtype"`
			IsError bool   `json:"is_error"`
			Result  string `json:"result"`
			Event   struct {
				Type  string `json:"type"`
				Delta struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"delta"`
			} `json:"event"`
		}
		if json.Unmarshal(p.lines.Bytes(), &event) != nil {
			continue
		}
		switch {
		case event.Type == "stream_event" && event.Event.Type == "content_block_delta" &&
			event.Event.Delta.Type == "text_delta":
			text.WriteString(event.Event.Delta.Text)
			if onText != nil {
				onText(Clean(r, text.String(), false))
			}
		case event.Type == "result":
			if event.IsError {
				msg := event.Result
				if msg == "" {
					msg = event.Subtype
				}
				return "", s.why(p, fmt.Errorf("claude: %s", msg))
			}
			whole := text.String()
			if whole == "" {
				whole = event.Result
			}
			return Clean(r, whole, true), nil
		}
	}
	return "", s.why(p, errors.New("claude ended without a suggestion"))
}

// why returns the reason p was stopped early, or err.
func (s *Suggester) why(p *proc, err error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p.reason != nil {
		return p.reason
	}
	return err
}

// Cancel ends the request running, if any; it reports whether one was.
func (s *Suggester) Cancel() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.current == nil {
		return false
	}
	s.current.stop(ErrCancelled)
	s.current = nil
	return true
}

// closeWait is how long Close waits for the processes it killed to exit.
const closeWait = 5 * time.Second

// Close stops every claude process the Suggester started, and waits
// for them to exit: until they have, Windows cannot remove the directory
// they run in.
func (s *Suggester) Close() {
	s.mu.Lock()
	s.closed = true
	if s.spareTimer != nil {
		s.spareTimer.Stop()
	}
	for _, p := range []*proc{s.current, s.spare} {
		if p != nil {
			p.stop(ErrCancelled)
		}
	}
	s.current, s.spare = nil, nil
	s.mu.Unlock()

	// Not under the lock: a request that is ending needs it. Nothing
	// starts after closed is set, so the count only goes down.
	exited := make(chan struct{})
	go func() {
		s.running.Wait()
		close(exited)
	}()
	select {
	case <-exited:
	case <-time.After(closeWait):
		s.opts.Log.Warn("claude processes for suggestions are still running", "waited", closeWait)
	}
}

// Clean returns text as it should be inserted at r's cursor: without a
// code fence around it, without indentation the line already has, and
// without the text that follows the cursor on its line repeated at its
// end. When final is false the text may still grow, so a fence that is
// only opened is dropped too.
func Clean(r Request, text string, final bool) string {
	t := text
	// A fence: ```lang\n...\n```
	if strings.HasPrefix(t, "```") {
		if nl := strings.IndexByte(t, '\n'); nl >= 0 {
			t = t[nl+1:]
		} else {
			return ""
		}
		if i := strings.LastIndex(t, "```"); i >= 0 {
			t = t[:i]
		}
		t = strings.TrimSuffix(t, "\n")
	}
	// The cursor's line so far: blank means its indentation is there already.
	lineStart := r.Prefix[strings.LastIndexByte(r.Prefix, '\n')+1:]
	if lineStart != "" && strings.TrimSpace(lineStart) == "" {
		t = strings.TrimPrefix(t, lineStart)
	} else if lineStart != "" && strings.HasPrefix(t, lineStart) {
		// The whole line repeated: keep what is new.
		t = t[len(lineStart):]
	}
	// The rest of the cursor's line repeated at the end.
	rest, _, _ := strings.Cut(r.Suffix, "\n")
	if rest = strings.TrimSpace(rest); final && rest != "" {
		t = strings.TrimSuffix(strings.TrimRight(t, " \t\n"), rest)
	}
	if final {
		t = strings.TrimRight(t, " \t\n")
	}
	return t
}
