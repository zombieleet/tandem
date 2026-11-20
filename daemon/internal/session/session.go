// Package session runs one Claude Code conversation: a claude process in
// headless stream-json mode, restarted with --resume after a cancel or a crash.
package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/victory/claude-pair/daemon/internal/mcphelper"
)

// Update is one session/update payload. "kind" says which fields it carries;
// see protocol/PROTOCOL.md.
type Update map[string]any

// Options configure a Session.
type Options struct {
	ID         string
	Cwd        string
	ClaudePath string
	Model      string
	// HelperCommand starts the MCP helper ("claude-paird mcp ..."). When
	// set, permission prompts go to its permission tool; when empty,
	// anything that would ask is denied.
	HelperCommand []string
	Log           *slog.Logger
	// Emit receives every update, in order, from one goroutine at a time.
	Emit func(Update)
	// OnIdle runs after a turn ends, once its updates have been emitted.
	OnIdle func()
}

var (
	// ErrBusy means a turn is running; cancel it or wait.
	ErrBusy = errors.New("Claude is still answering; cancel the turn or wait for it to finish")
	// ErrClosed means the session was closed.
	ErrClosed = errors.New("the session is closed")
)

// EditingPrompt tells Claude how files change in claude-pair.
const EditingPrompt = "You are running inside claude-pair, which connects you to the user's Emacs. " +
	"Change files only with " + mcphelper.EditToolName + " and create or overwrite them only with " +
	mcphelper.WriteToolName + "; the built-in Edit, Write and NotebookEdit tools are turned off. " +
	"The user reviews every edit in Emacs, where the file may have unsaved changes, so old_string must " +
	"match what you last read. If the user rejects an edit, read their note and adjust instead of " +
	"sending the same change again. Use absolute paths inside the project."

// helperTimeoutMs is how long one MCP call may take: 24 hours.
const helperTimeoutMs = 24 * 60 * 60 * 1000

const (
	cancelGrace = 5 * time.Second
	closeGrace  = 3 * time.Second
	maxLine     = 64 << 20
)

// Session is one conversation with Claude.
type Session struct {
	opts Options

	// emitMu keeps updates in order across the reader and the callers.
	emitMu sync.Mutex

	mu        sync.Mutex
	proc      *process // the process that takes the next prompt, or nil
	resumable bool     // a transcript exists, so later starts use --resume
	closed    bool
	totalCost float64 // sum of completed turns, across processes
}

type toolStart struct {
	name, title string
	at          time.Time
}

type process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stderr *tailBuffer
	done   chan struct{}

	// Guarded by Session.mu.
	turnOpen   bool    // a prompt was sent and its result has not arrived
	cancelling bool    // SIGINT was sent for the open turn
	cost       float64 // total_cost_usd last reported by this process
	currentMsg string
	streamed   map[string]bool
	tools      map[string]toolStart
}

// New returns a Session. No claude process starts until the first prompt.
func New(opts Options) *Session {
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	if opts.Emit == nil {
		opts.Emit = func(Update) {}
	}
	if opts.OnIdle == nil {
		opts.OnIdle = func() {}
	}
	opts.Log = opts.Log.With("session", opts.ID)
	return &Session{opts: opts}
}

// ID returns the session id, which is also Claude Code's session id.
func (s *Session) ID() string { return s.opts.ID }

// Cwd returns the project directory claude runs in.
func (s *Session) Cwd() string { return s.opts.Cwd }

// Busy reports whether a turn is running.
func (s *Session) Busy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.proc != nil && s.proc.turnOpen
}

// TotalCostUSD is the cost of every completed turn so far.
func (s *Session) TotalCostUSD() float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.totalCost
}

// Prompt sends text as the next user message, starting claude if needed.
func (s *Session) Prompt(text string) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrClosed
	}
	if s.proc != nil && s.proc.turnOpen {
		s.mu.Unlock()
		return ErrBusy
	}
	var updates []Update
	if s.proc == nil {
		if err := s.startLocked(); err != nil {
			s.mu.Unlock()
			return err
		}
		updates = append(updates, Update{"kind": "status", "state": "starting"})
	}
	line, _ := json.Marshal(map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": text},
	})
	if _, err := s.proc.stdin.Write(append(line, '\n')); err != nil {
		s.mu.Unlock()
		return fmt.Errorf("cannot write to claude: %w", err)
	}
	s.proc.turnOpen, s.resumable = true, true
	updates = append(updates, Update{"kind": "status", "state": "running"})
	s.mu.Unlock()
	s.emit(updates...)
	return nil
}

// Cancel interrupts the running turn. It returns false when nothing runs.
// Claude Code ends the turn and exits; the next prompt resumes the session.
func (s *Session) Cancel() bool {
	s.mu.Lock()
	p := s.proc
	if p == nil || !p.turnOpen || p.cancelling {
		s.mu.Unlock()
		return false
	}
	p.cancelling = true
	s.mu.Unlock()

	s.emit(Update{"kind": "status", "state": "cancelling"})
	_ = p.cmd.Process.Signal(os.Interrupt)
	go func() {
		select {
		case <-p.done:
		case <-time.After(cancelGrace):
			s.opts.Log.Warn("claude ignored SIGINT; killing it")
			_ = p.cmd.Process.Kill()
		}
	}()
	return true
}

// Close stops claude and refuses further prompts. It waits for the process.
func (s *Session) Close() {
	s.mu.Lock()
	s.closed = true
	p := s.proc
	s.mu.Unlock()
	if p == nil {
		return
	}
	_ = p.stdin.Close()
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
	case <-time.After(closeGrace):
		_ = p.cmd.Process.Kill()
		<-p.done
	}
}

// Args returns the command-line arguments for a claude process.
func (s *Session) Args(resume bool) []string {
	args := []string{
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--permission-mode", "default",
		// Emacs owns every write (milestone 4); the built-in writers stay off.
		"--disallowedTools", "Edit,Write,NotebookEdit",
	}
	if cmd := s.opts.HelperCommand; len(cmd) > 0 {
		config, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{
			mcphelper.ServerName: map[string]any{
				"type": "stdio", "command": cmd[0], "args": cmd[1:],
				// A review may wait for the user a long time; this per-server
				// limit also overrides a short MCP_TOOL_TIMEOUT.
				"timeout": helperTimeoutMs,
			},
		}})
		args = append(args, "--mcp-config", string(config),
			"--permission-prompt-tool", mcphelper.PermissionToolName,
			// The user reviews every edit in Emacs; a second question first
			// would only be noise.
			"--allowedTools", mcphelper.EditToolName+","+mcphelper.WriteToolName,
			"--append-system-prompt", EditingPrompt)
	} else {
		args = append(args, "--permission-prompts", "none")
	}
	if s.opts.Model != "" {
		args = append(args, "--model", s.opts.Model)
	}
	if resume {
		return append(args, "--resume", s.opts.ID)
	}
	return append(args, "--session-id", s.opts.ID)
}

func (s *Session) startLocked() error {
	cmd := exec.Command(s.opts.ClaudePath, s.Args(s.resumable)...)
	cmd.Dir = s.opts.Cwd
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	tail := newTailBuffer(8 << 10)
	cmd.Stderr = tail
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot start claude: %w", err)
	}
	p := &process{cmd: cmd, stdin: stdin, stderr: tail, done: make(chan struct{}),
		streamed: map[string]bool{}, tools: map[string]toolStart{}}
	s.proc = p
	s.opts.Log.Info("claude started", "pid", cmd.Process.Pid, "resume", s.resumable)
	go s.run(p, stdout)
	return nil
}

// run reads claude's events until its output closes, then reaps it.
func (s *Session) run(p *process, stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64<<10), maxLine)
	for scanner.Scan() {
		var event map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			s.opts.Log.Debug("ignoring a line that is not JSON", "error", err)
			continue
		}
		s.mu.Lock()
		updates, turnEnded := s.translate(p, event)
		if p != s.proc && !turnEnded {
			updates = nil // a detached process that is on its way out
		}
		s.mu.Unlock()
		s.emit(updates...)
		if turnEnded {
			s.opts.OnIdle()
		}
	}
	if err := scanner.Err(); err != nil {
		s.opts.Log.Warn("reading claude's output failed", "error", err)
	}
	err := p.cmd.Wait()
	s.exited(p, err)
}

func (s *Session) exited(p *process, err error) {
	s.mu.Lock()
	if s.proc == p {
		s.proc = nil
	}
	turnOpen, cancelling, closed := p.turnOpen, p.cancelling, s.closed
	p.turnOpen = false
	s.mu.Unlock()

	code := -1
	if p.cmd.ProcessState != nil {
		code = p.cmd.ProcessState.ExitCode()
	}
	s.opts.Log.Info("claude exited", "code", code, "error", err)
	var updates []Update
	switch {
	case closed:
	case turnOpen && cancelling:
		updates = append(updates, Update{"kind": "result", "cancelled": true}, Update{"kind": "status", "state": "idle"})
	case turnOpen:
		updates = append(updates, s.crashUpdate(p, code), Update{"kind": "status", "state": "idle"})
	case code != 0 && !cancelling:
		updates = append(updates, s.crashUpdate(p, code))
	}
	s.emit(updates...)
	close(p.done)
	if turnOpen && !closed {
		s.opts.OnIdle()
	}
}

func (s *Session) crashUpdate(p *process, code int) Update {
	return Update{
		"kind":     "error",
		"message":  fmt.Sprintf("claude stopped unexpectedly (exit code %d)", code),
		"stderr":   p.stderr.String(),
		"exitCode": code,
	}
}

func (s *Session) emit(updates ...Update) {
	if len(updates) == 0 {
		return
	}
	s.emitMu.Lock()
	defer s.emitMu.Unlock()
	for _, u := range updates {
		s.opts.Emit(u)
	}
}

// tailBuffer keeps the last bytes written to it.
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func newTailBuffer(max int) *tailBuffer { return &tailBuffer{max: max} }

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}
