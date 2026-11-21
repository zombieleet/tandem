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
	"runtime"
	"strings"
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
	// Env changes claude's environment, which is otherwise the daemon's: a
	// name with a value sets it, a name with nil removes it. Values are
	// credentials, so they are never logged.
	Env map[string]*string
	// Instructions are the user's standing instructions for Claude, such as
	// how to write; they go into the system prompt of every turn.
	Instructions string
	// HelperCommand starts the MCP helper ("claude-paird mcp ..."). When
	// set, permission prompts go to its permission tool; when empty,
	// anything that would ask is denied.
	HelperCommand []string
	Log           *slog.Logger
	// Emit receives every update, in order, from one goroutine at a time.
	Emit func(Update)
	// OnIdle runs after a turn ends, once its updates have been emitted.
	OnIdle func()
	// Resume continues the conversation with ID that Claude Code already
	// keeps on disk, instead of starting a new one.
	Resume bool
	// InterruptByMessage cancels a turn with an interrupt control request
	// on claude's stdin, which ends the turn and keeps the process, instead
	// of SIGINT, which ends the process. Windows has no SIGINT to send.
	InterruptByMessage bool
}

// DefaultInterruptByMessage is how turns are cancelled where Options does
// not say: by message on Windows, by SIGINT elsewhere.
var DefaultInterruptByMessage = runtime.GOOS == "windows"

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
	"sending the same change again. Use absolute paths inside the project. " +
	"To show the user a file or the lines you are talking about, call " + mcphelper.OpenFileToolName +
	" with a line; do not open files only to read them. The user's Emacs keeps at most 5 windows; " +
	mcphelper.ListWindowsToolName + " lists them and " + mcphelper.CloseWindowToolName +
	" closes the ones you opened. Emacs also knows things grep does not. To find where a symbol is " +
	"defined or where it is used, call " + mcphelper.XrefToolName + " first: when the user's Emacs runs a " +
	"language server it answers exactly, and it tells you when there is none; only then use grep. " +
	"Call " + mcphelper.DiagnosticsToolName + " after editing to see errors, " + mcphelper.ImenuToolName +
	" for a file's outline, and " + mcphelper.SelectionToolName + " when the user says \"this\" or \"here\"."

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
	resumeAt  string   // the message the next start goes back to, or ""
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
	if runtime.GOOS == "windows" {
		// There is no SIGINT to send.
		opts.InterruptByMessage = true
	}
	return &Session{opts: opts, resumable: opts.Resume}
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
	byMessage := s.opts.InterruptByMessage
	if byMessage {
		line := `{"type":"control_request","request_id":"cancel-` + fmt.Sprint(time.Now().UnixNano()) +
			`","request":{"subtype":"interrupt"}}` + "\n"
		if _, err := io.WriteString(p.stdin, line); err != nil {
			byMessage = false
		}
	}
	s.mu.Unlock()

	s.emit(Update{"kind": "status", "state": "cancelling"})
	if !byMessage {
		_ = p.cmd.Process.Signal(os.Interrupt)
	}
	go func() {
		deadline := time.After(cancelGrace)
		for {
			select {
			case <-p.done:
				return
			case <-deadline:
				s.mu.Lock()
				stuck := p.turnOpen && p.cancelling
				s.mu.Unlock()
				if stuck {
					s.opts.Log.Warn("claude did not stop the turn; killing it")
					_ = p.cmd.Process.Kill()
				}
				return
			case <-time.After(50 * time.Millisecond):
				// A turn ended by message leaves the process running.
				s.mu.Lock()
				ended := !p.turnOpen
				s.mu.Unlock()
				if ended {
					return
				}
			}
		}
	}()
	return true
}

// Rewind goes back to just after Claude's message uuid: the turns after it
// are forgotten, and the next prompt continues from there. The running
// claude, which remembers them, stops. It fails with ErrBusy during a turn.
func (s *Session) Rewind(uuid string) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrClosed
	}
	p := s.proc
	if p != nil && p.turnOpen {
		s.mu.Unlock()
		return ErrBusy
	}
	s.proc, s.resumable, s.resumeAt = nil, true, uuid
	if p != nil {
		// An exit forced below is not a crash to report.
		p.cancelling = true
	}
	s.mu.Unlock()
	if p != nil {
		_ = p.stdin.Close()
		select {
		case <-p.done:
		case <-time.After(closeGrace):
			_ = p.cmd.Process.Kill()
			<-p.done
		}
	}
	s.opts.Log.Info("session rewound", "to", uuid)
	return nil
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
			"--allowedTools", strings.Join(append([]string{mcphelper.EditToolName, mcphelper.WriteToolName},
				mcphelper.LayoutToolNames...), ","))
	} else {
		args = append(args, "--permission-prompts", "none")
	}
	if prompt := s.systemPrompt(); prompt != "" {
		args = append(args, "--append-system-prompt", prompt)
	}
	if s.opts.Model != "" {
		args = append(args, "--model", s.opts.Model)
	}
	if resume {
		args = append(args, "--resume", s.opts.ID)
		if s.resumeAt != "" {
			args = append(args, "--resume-session-at", s.resumeAt)
		}
		return args
	}
	return append(args, "--session-id", s.opts.ID)
}

// systemPrompt is what claude-pair adds to Claude's system prompt: how
// files change here, when Emacs is reachable, then the user's instructions.
func (s *Session) systemPrompt() string {
	var parts []string
	if len(s.opts.HelperCommand) > 0 {
		parts = append(parts, EditingPrompt)
	}
	if text := strings.TrimSpace(s.opts.Instructions); text != "" {
		parts = append(parts, "The user's instructions for every answer: "+text)
	}
	return strings.Join(parts, "\n\n")
}

func (s *Session) startLocked() error {
	cmd := exec.Command(s.opts.ClaudePath, s.Args(s.resumable)...)
	cmd.Dir = s.opts.Cwd
	if len(s.opts.Env) > 0 {
		cmd.Env = MergeEnv(os.Environ(), s.opts.Env)
	}
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
	// Only the first start after a rewind goes back; later ones follow the new branch.
	s.resumeAt = ""
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

// MergeEnv returns base, a list of NAME=value, changed by overrides: a name
// with a value replaces or adds it, a name with nil removes it.
func MergeEnv(base []string, overrides map[string]*string) []string {
	var out []string
	for _, kv := range base {
		name, _, _ := strings.Cut(kv, "=")
		if _, changed := overrides[name]; !changed {
			out = append(out, kv)
		}
	}
	for name, value := range overrides {
		if value != nil {
			out = append(out, name+"="+*value)
		}
	}
	return out
}
