// Package server is the daemon: a Unix socket server speaking the claude-pair protocol.
package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"math"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/victory/claude-pair/daemon/internal/endpoint"
	"github.com/victory/claude-pair/daemon/internal/history"
	"github.com/victory/claude-pair/daemon/internal/paths"
	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/rpc"
	"github.com/victory/claude-pair/daemon/internal/session"
)

// AlreadyRunningError means another daemon answers on the socket.
type AlreadyRunningError struct{ Path string }

func (e *AlreadyRunningError) Error() string {
	return "another claude-paird is already listening on " + e.Path
}

// UnsafeDirError means the socket's directory could let other users reach the daemon.
type UnsafeDirError struct{ msg string }

func (e *UnsafeDirError) Error() string { return e.msg }

// Options configure a Daemon.
type Options struct {
	SocketPath string
	// IdleTimeout stops the daemon after this long with no clients. 0 never stops.
	IdleTimeout time.Duration
	Version     string
	Log         *slog.Logger
	// HelperPath is the claude-paird executable that Claude Code starts as
	// "claude-paird mcp". It defaults to this program.
	HelperPath string
	// TCP listens on a local TCP port, written with a token to an endpoint
	// file at SocketPath, instead of on a Unix socket there.
	TCP bool
	// InterruptByMessage cancels turns by message instead of SIGINT; see
	// session.Options. It is always so on Windows.
	InterruptByMessage bool
}

type client struct {
	conn        *rpc.Conn
	initialized atomic.Bool
	name        atomic.Value // string
	isHelper    atomic.Bool  // an MCP helper, not an Emacs
}

func (c *client) helper() bool { return c.isHelper.Load() }

// sessionEntry is a session and the clients that receive its updates.
type sessionEntry struct {
	s    *session.Session
	subs map[*client]bool
	last *client // sent the last prompt; answers permission prompts
}

// Daemon serves clients on a Unix socket.
type Daemon struct {
	opts    Options
	ln      net.Listener
	inode   uint64
	token   string // what TCP clients must send in initialize; "" for a socket
	started time.Time
	wg      sync.WaitGroup

	mu          sync.Mutex
	clients     map[int]*client
	sessions    map[string]*sessionEntry
	permissions map[string]*pendingPermission
	edits       map[string]*pendingEdit
	tools       map[string]*pendingTool
	nextClient  int
	idle        *time.Timer
	stopping    bool
	reason      string

	stopOnce sync.Once
	done     chan struct{}
}

// New returns a Daemon; call Start to listen.
func New(opts Options) *Daemon {
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	if opts.HelperPath == "" {
		opts.HelperPath = defaultHelperPath()
	}
	return &Daemon{
		opts:        opts,
		clients:     map[int]*client{},
		sessions:    map[string]*sessionEntry{},
		permissions: map[string]*pendingPermission{},
		edits:       map[string]*pendingEdit{},
		tools:       map[string]*pendingTool{},
		done:        make(chan struct{}),
	}
}

// Done is closed once the daemon has stopped.
func (d *Daemon) Done() <-chan struct{} { return d.done }

// StopReason says why the daemon stopped.
func (d *Daemon) StopReason() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.reason
}

// Start prepares the socket directory, replaces a stale socket and listens.
func (d *Daemon) Start() error {
	if d.opts.TCP {
		return d.startTCP()
	}
	path := d.opts.SocketPath
	if n := len(path); n > paths.MaxSocketPathBytes {
		return fmt.Errorf("socket path is %d bytes, more than the %d allowed: %s", n, paths.MaxSocketPathBytes, path)
	}
	if err := PrepareSocketDir(filepath.Dir(path)); err != nil {
		return err
	}
	if err := clearStaleSocket(path); err != nil {
		return err
	}
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		if errors.Is(err, syscall.EADDRINUSE) {
			return &AlreadyRunningError{Path: path}
		}
		return err
	}
	// We remove the socket ourselves, and only if it is still ours.
	ln.SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return err
	}
	inode, err := inodeOf(path)
	if err != nil {
		ln.Close()
		return err
	}
	d.ln, d.inode, d.started = ln, inode, time.Now()
	go d.acceptLoop()
	d.armIdle()
	d.opts.Log.Info("listening", "socket", path, "pid", os.Getpid(), "version", d.opts.Version)
	return nil
}

// startTCP listens on a local port and writes the endpoint file.
func (d *Daemon) startTCP() error {
	path := d.opts.SocketPath
	if err := PrepareSocketDir(filepath.Dir(path)); err != nil {
		return err
	}
	if CanConnect(path, time.Second) {
		return &AlreadyRunningError{Path: path}
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	token := endpoint.NewToken()
	if err := endpoint.Write(path, endpoint.Info{Port: ln.Addr().(*net.TCPAddr).Port, Token: token, PID: os.Getpid()}); err != nil {
		ln.Close()
		return err
	}
	d.ln, d.token, d.started = ln, token, time.Now()
	go d.acceptLoop()
	d.armIdle()
	d.opts.Log.Info("listening", "endpoint", path, "address", ln.Addr().String(), "pid", os.Getpid(),
		"version", d.opts.Version)
	return nil
}

// tokenOK reports whether params carry this daemon's token, as a TCP client
// must. A socket needs none: its mode keeps others out.
func (d *Daemon) tokenOK(params json.RawMessage) bool {
	if d.token == "" {
		return true
	}
	var p struct {
		Token string `json:"token"`
	}
	_ = json.Unmarshal(params, &p)
	return subtle.ConstantTimeCompare([]byte(p.Token), []byte(d.token)) == 1
}

// Stop closes every connection, removes the socket and closes Done. It is
// safe to call more than once and from any goroutine; it returns once stopped.
func (d *Daemon) Stop(reason string) {
	d.stopOnce.Do(func() {
		d.mu.Lock()
		d.stopping, d.reason = true, reason
		if d.idle != nil {
			d.idle.Stop()
		}
		clients := make([]*client, 0, len(d.clients))
		for _, c := range d.clients {
			clients = append(clients, c)
		}
		sessions := make([]*session.Session, 0, len(d.sessions))
		for _, e := range d.sessions {
			sessions = append(sessions, e.s)
		}
		d.mu.Unlock()
		for _, s := range sessions {
			d.withdrawPermissions(s.ID(), "claude-paird is stopping.")
		}
		d.mu.Lock()
		d.sessions = map[string]*sessionEntry{}
		d.mu.Unlock()

		d.opts.Log.Info("stopping", "reason", reason)
		var closing sync.WaitGroup
		for _, s := range sessions {
			closing.Add(1)
			go func() { defer closing.Done(); s.Close() }()
		}
		closing.Wait()
		if d.ln != nil {
			d.ln.Close()
		}
		for _, c := range clients {
			c.conn.Close()
		}
		waited := make(chan struct{})
		go func() { d.wg.Wait(); close(waited) }()
		select {
		case <-waited:
		case <-time.After(2 * time.Second):
			d.opts.Log.Warn("clients did not close in time")
		}
		if d.token != "" {
			// The endpoint file, unless another daemon has written its own.
			if info, err := endpoint.Read(d.opts.SocketPath); err == nil && info.Token == d.token {
				_ = os.Remove(d.opts.SocketPath)
			}
		} else if err := removeSocketIfOurs(d.opts.SocketPath, d.inode); err != nil {
			d.opts.Log.Warn("cannot remove socket", "error", err)
		}
		d.opts.Log.Info("stopped", "reason", reason)
		close(d.done)
	})
	<-d.done
}

// Status reports the daemon's state.
func (d *Daemon) Status() protocol.StatusResult {
	d.mu.Lock()
	clients, sessions := d.emacsClientsLocked(), len(d.sessions)
	d.mu.Unlock()
	return protocol.StatusResult{
		Version:            d.opts.Version,
		ProtocolVersion:    protocol.Version,
		PID:                os.Getpid(),
		UptimeSeconds:      int(math.Round(time.Since(d.started).Seconds())),
		Clients:            clients,
		Sessions:           sessions,
		SocketPath:         d.opts.SocketPath,
		IdleTimeoutSeconds: d.opts.IdleTimeout.Seconds(),
	}
}

func (d *Daemon) acceptLoop() {
	for {
		nc, err := d.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			d.opts.Log.Warn("accept failed", "error", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		d.accept(nc)
	}
}

func (d *Daemon) accept(nc net.Conn) {
	d.mu.Lock()
	if d.stopping {
		d.mu.Unlock()
		nc.Close()
		return
	}
	d.nextClient++
	id := d.nextClient
	c := &client{}
	c.name.Store("")
	c.conn = rpc.New(id, nc, func(ctx context.Context, _ *rpc.Conn, method string, params json.RawMessage) (any, error) {
		return d.handle(ctx, c, method, params)
	}, nil, d.opts.Log)
	d.clients[id] = c
	if d.idle != nil {
		d.idle.Stop()
	}
	d.wg.Add(1)
	d.mu.Unlock()

	d.opts.Log.Debug("client connected", "client", id)
	go func() {
		defer d.wg.Done()
		c.conn.Serve()
		d.mu.Lock()
		delete(d.clients, id)
		for _, e := range d.sessions {
			delete(e.subs, c)
		}
		d.mu.Unlock()
		d.opts.Log.Debug("client disconnected", "client", id, "name", c.name.Load())
		d.armIdle()
	}()
}

func (d *Daemon) handle(ctx context.Context, c *client, method string, params json.RawMessage) (any, error) {
	switch method {
	case "initialize":
		return d.initialize(c, params)
	case "shutdown":
		// Allowed before initialize, so a client of any version can stop a
		// daemon whose protocol it does not speak.
		// Before initialize, over TCP, only with the token.
		if !c.initialized.Load() && !d.tokenOK(params) {
			return nil, rpc.Errorf(protocol.Unauthorized, "shutdown needs the token from the endpoint file")
		}
		return rpc.Then{
			Result: map[string]bool{"ok": true},
			After:  func() { go d.Stop("shutdown request") },
		}, nil
	}
	if !c.initialized.Load() {
		return nil, rpc.Errorf(protocol.NotInitialized, "send initialize before %s", method)
	}
	switch method {
	case "daemon/status":
		return d.Status(), nil
	case "session/new":
		return d.newSession(c, params)
	case "session/list":
		return d.listSessions(params)
	case "session/all":
		return d.allSessions(), nil
	case "session/resume":
		return d.resumeSession(c, params)
	case "session/prompt":
		return d.prompt(c, params)
	case "session/commands":
		e, err := d.lookup(params, nil)
		if err != nil {
			return nil, err
		}
		commands, err := e.s.Commands(ctx)
		if err != nil {
			return nil, rpc.Errorf(protocol.ClaudeUnavailable, "%s", err.Error())
		}
		return map[string]any{"commands": commands}, nil
	case "session/history":
		var id string
		e, err := d.lookup(params, &id)
		if err != nil {
			return nil, err
		}
		entries, err := d.history(e, id, params)
		if err != nil {
			return nil, err
		}
		return map[string]any{"history": entries}, nil
	case "session/rewind":
		var p struct {
			Before string `json:"before"`
		}
		var id string
		e, err := d.lookup(params, &id)
		if err != nil {
			return nil, err
		}
		if json.Unmarshal(params, &p) != nil || p.Before == "" {
			return nil, rpc.Errorf(protocol.InvalidParams, "session/rewind needs before, the message to go back to")
		}
		entries, err := d.history(e, id, params)
		if err != nil {
			return nil, err
		}
		known := false
		for _, entry := range entries {
			known = known || entry.Before == p.Before
		}
		if !known {
			return nil, rpc.Errorf(protocol.InvalidParams, "%s is not a point this conversation can go back to", p.Before)
		}
		d.withdrawPermissions(id, "The user went back to an earlier turn.")
		if err := e.s.Rewind(p.Before); err != nil {
			if errors.Is(err, session.ErrBusy) {
				return nil, rpc.Errorf(protocol.SessionBusy, "%s", err.Error())
			}
			return nil, rpc.Errorf(protocol.UnknownSession, "%s", err.Error())
		}
		return map[string]bool{"ok": true}, nil
	case "session/cancel":
		var id string
		e, err := d.lookup(params, &id)
		if err != nil {
			return nil, err
		}
		d.withdrawPermissions(id, "The user stopped the turn.")
		return map[string]bool{"cancelled": e.s.Cancel()}, nil
	case "session/close":
		var id string
		e, err := d.lookup(params, &id)
		if err != nil {
			return nil, err
		}
		d.withdrawPermissions(id, "The session was closed.")
		d.mu.Lock()
		delete(d.sessions, id)
		d.mu.Unlock()
		e.s.Close()
		d.armIdle()
		return map[string]bool{"ok": true}, nil
	case "helper/permission":
		return d.askPermission(ctx, c, params)
	case "permission/answer":
		return d.answerPermission(c, params)
	case "helper/edit":
		return d.proposeEdit(ctx, c, params)
	case "edit/answer":
		return d.answerEdit(c, params)
	case "helper/emacs":
		return d.callEmacs(ctx, c, params)
	case "tool/result":
		return d.answerTool(c, params)
	default:
		return nil, rpc.Errorf(protocol.MethodNotFound, "unknown method %s", method)
	}
}

func (d *Daemon) initialize(c *client, params json.RawMessage) (any, error) {
	var p protocol.InitializeParams
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.ProtocolVersion == nil {
		return nil, rpc.Errorf(protocol.InvalidParams, "initialize needs a protocolVersion string")
	}
	if !d.tokenOK(params) {
		return nil, rpc.Errorf(protocol.Unauthorized, "initialize needs the token from the endpoint file")
	}
	if !protocol.Compatible(*p.ProtocolVersion, protocol.Version) {
		return nil, &rpc.Error{
			Code: protocol.IncompatibleProtocol,
			Message: fmt.Sprintf("client protocol %s is not compatible with daemon protocol %s",
				*p.ProtocolVersion, protocol.Version),
			Data: map[string]any{"daemonProtocolVersion": protocol.Version, "daemonVersion": d.opts.Version,
				"pid": os.Getpid()},
		}
	}
	c.initialized.Store(true)
	if p.ClientInfo != nil {
		c.name.Store(p.ClientInfo.Name)
	}
	if role, _ := p.Capabilities["role"].(string); role == "mcp-helper" {
		c.isHelper.Store(true)
	}
	d.opts.Log.Info("client initialized", "client", c.conn.ID, "name", c.name.Load())
	return protocol.InitializeResult{
		ProtocolVersion: protocol.Version,
		ServerInfo:      protocol.ServerInfo{Name: "claude-paird", Version: d.opts.Version},
		PID:             os.Getpid(),
		Capabilities:    map[string]any{},
	}, nil
}

// sessionParams are what session/new and session/resume take.
type sessionParams struct {
	SessionID  string             `json:"sessionId"`
	Cwd        string             `json:"cwd"`
	ClaudePath string             `json:"claudePath"`
	Model      string             `json:"model"`
	Env        map[string]*string `json:"env"`
	// Instructions go into the system prompt of every turn.
	Instructions string `json:"instructions"`
}

// parseSessionParams reads and checks params for method.
func parseSessionParams(method string, params json.RawMessage) (*sessionParams, error) {
	var p sessionParams
	if len(params) == 0 || json.Unmarshal(params, &p) != nil {
		return nil, rpc.Errorf(protocol.InvalidParams, "%s needs cwd and claudePath", method)
	}
	for name := range p.Env {
		if name == "" || strings.ContainsAny(name, "=\x00") {
			return nil, rpc.Errorf(protocol.InvalidParams, "env has a bad variable name %q", name)
		}
	}
	if info, err := os.Stat(p.Cwd); !filepath.IsAbs(p.Cwd) || err != nil || !info.IsDir() {
		return nil, rpc.Errorf(protocol.InvalidParams, "cwd must be an existing absolute directory, got %q", p.Cwd)
	}
	return &p, nil
}

// newSession checks the project directory and the claude command, then
// registers a session. Claude starts with the first prompt.
func (d *Daemon) newSession(c *client, params json.RawMessage) (any, error) {
	p, err := parseSessionParams("session/new", params)
	if err != nil {
		return nil, err
	}
	version, err := session.CheckClaude(p.ClaudePath)
	if err != nil {
		return nil, rpc.Errorf(protocol.ClaudeUnavailable, "%s", err.Error())
	}
	id := newSessionID()
	d.startSession(c, id, p, false)
	d.opts.Log.Info("session created", "session", id, "cwd", p.Cwd, "claude", version)
	return map[string]string{"sessionId": id, "claudeVersion": version}, nil
}

// startSession registers session id for client c.
func (d *Daemon) startSession(c *client, id string, p *sessionParams, resume bool) {
	s := session.New(session.Options{
		ID:           id,
		Cwd:          p.Cwd,
		ClaudePath:   p.ClaudePath,
		Model:        p.Model,
		Env:          p.Env,
		Instructions: p.Instructions,
		HelperCommand: []string{d.opts.HelperPath, "mcp",
			"--socket", d.opts.SocketPath, "--session", id},
		Log:                d.opts.Log,
		Emit:               func(u session.Update) { d.broadcast(id, u) },
		OnIdle:             d.armIdle,
		Resume:             resume,
		InterruptByMessage: d.opts.InterruptByMessage || session.DefaultInterruptByMessage,
	})
	d.mu.Lock()
	d.sessions[id] = &sessionEntry{s: s, subs: map[*client]bool{c: true}}
	d.mu.Unlock()
}

// history reads the conversation of session id, entry e, with tool titles.
// params may carry env, for CLAUDE_CONFIG_DIR.
func (d *Daemon) history(e *sessionEntry, id string, params json.RawMessage) ([]history.Entry, error) {
	var p struct {
		Env map[string]*string `json:"env"`
	}
	_ = json.Unmarshal(params, &p)
	entries, err := history.Read(history.ConfigDir(p.Env), e.s.Cwd(), id)
	if errors.Is(err, history.ErrNoChat) {
		return []history.Entry{}, nil
	}
	if err != nil {
		return nil, rpc.Errorf(protocol.InternalError, "reading the conversation: %s", err.Error())
	}
	for i := range entries {
		if entries[i].Kind == "tool" {
			entries[i].Title = session.ToolTitle(entries[i].Name, entries[i].Input, e.s.Cwd())
		}
	}
	return entries, nil
}

// allSessions lists every session open in this daemon, whatever its
// project: the dashboard shows the ones no Emacs window has.
func (d *Daemon) allSessions() any {
	type open struct {
		SessionID string  `json:"sessionId"`
		Cwd       string  `json:"cwd"`
		Busy      bool    `json:"busy"`
		CostUSD   float64 `json:"costUsd"`
		Followers int     `json:"followers"`
	}
	d.mu.Lock()
	entries := map[string]*sessionEntry{}
	out := make([]open, 0, len(d.sessions))
	for id, e := range d.sessions {
		followers := 0
		for c := range e.subs {
			select {
			case <-c.conn.Done():
			default:
				if !c.helper() {
					followers++
				}
			}
		}
		entries[id] = e
		out = append(out, open{SessionID: id, Cwd: e.s.Cwd(), Followers: followers})
	}
	d.mu.Unlock()
	// Busy and cost take the session's own lock, so outside the daemon's.
	for i := range out {
		e := entries[out[i].SessionID]
		out[i].Busy, out[i].CostUSD = e.s.Busy(), e.s.TotalCostUSD()
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Cwd < out[j].Cwd || out[i].Cwd == out[j].Cwd && out[i].SessionID < out[j].SessionID
	})
	return map[string]any{"sessions": out}
}

// listSessions returns the earlier conversations about a project, newest
// first, marking those that still run in this daemon.
func (d *Daemon) listSessions(params json.RawMessage) (any, error) {
	var p struct {
		Cwd   string             `json:"cwd"`
		Env   map[string]*string `json:"env"`
		Limit int                `json:"limit"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || !filepath.IsAbs(p.Cwd) {
		return nil, rpc.Errorf(protocol.InvalidParams, "session/list needs an absolute cwd")
	}
	if p.Limit <= 0 || p.Limit > 200 {
		p.Limit = 50
	}
	chats, err := history.List(history.ConfigDir(p.Env), p.Cwd, p.Limit)
	if err != nil {
		return nil, rpc.Errorf(protocol.InternalError, "reading Claude Code's conversations: %s", err.Error())
	}
	type listed struct {
		history.Chat
		Running bool `json:"running"`
		Busy    bool `json:"busy"`
	}
	out := make([]listed, 0, len(chats))
	d.mu.Lock()
	for _, chat := range chats {
		l := listed{Chat: chat}
		if e, ok := d.sessions[chat.SessionID]; ok {
			l.Running, l.Busy = true, e.s.Busy()
		}
		out = append(out, l)
	}
	d.mu.Unlock()
	return map[string]any{"sessions": out}, nil
}

// resumeSession reopens a conversation: one still running here is followed
// by the client; another is continued with claude --resume. Either way the
// result carries the conversation so far.
func (d *Daemon) resumeSession(c *client, params json.RawMessage) (any, error) {
	p, err := parseSessionParams("session/resume", params)
	if err != nil {
		return nil, err
	}
	if !history.ValidID(p.SessionID) {
		return nil, rpc.Errorf(protocol.InvalidParams, "session/resume needs a sessionId")
	}
	entries, err := history.Read(history.ConfigDir(p.Env), p.Cwd, p.SessionID)
	if entries == nil {
		entries = []history.Entry{}
	}
	d.mu.Lock()
	e, running := d.sessions[p.SessionID]
	if running && e.s.Cwd() != p.Cwd {
		// The same conversation from another folder is not this project's.
		d.mu.Unlock()
		return nil, rpc.Errorf(protocol.UnknownSession, "no conversation %s about %s", p.SessionID, p.Cwd)
	}
	if running {
		e.subs[c] = true
		e.last = c
	}
	d.mu.Unlock()
	if err != nil && !running {
		return nil, rpc.Errorf(protocol.UnknownSession, "no conversation %s about %s", p.SessionID, p.Cwd)
	}
	for i := range entries {
		if entries[i].Kind == "tool" {
			entries[i].Title = session.ToolTitle(entries[i].Name, entries[i].Input, p.Cwd)
		}
	}
	result := map[string]any{"sessionId": p.SessionID, "history": entries, "running": running}
	if running {
		result["busy"] = e.s.Busy()
		result["costUsd"] = e.s.TotalCostUSD()
		d.opts.Log.Info("session reattached", "session", p.SessionID)
		return result, nil
	}
	version, err := session.CheckClaude(p.ClaudePath)
	if err != nil {
		return nil, rpc.Errorf(protocol.ClaudeUnavailable, "%s", err.Error())
	}
	d.startSession(c, p.SessionID, p, true)
	result["claudeVersion"] = version
	d.opts.Log.Info("session resumed", "session", p.SessionID, "cwd", p.Cwd, "claude", version)
	return result, nil
}

func (d *Daemon) prompt(c *client, params json.RawMessage) (any, error) {
	var p struct {
		SessionID string `json:"sessionId"`
		Text      string `json:"text"`
		// PermissionMode is "default" or "plan"; empty means default.
		PermissionMode string `json:"permissionMode"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.Text == "" {
		return nil, rpc.Errorf(protocol.InvalidParams, "session/prompt needs a sessionId and some text")
	}
	if p.PermissionMode != "" && p.PermissionMode != "default" && p.PermissionMode != "plan" {
		return nil, rpc.Errorf(protocol.InvalidParams, `permissionMode must be "default" or "plan", got %q`, p.PermissionMode)
	}
	d.mu.Lock()
	e, ok := d.sessions[p.SessionID]
	if ok {
		e.subs[c] = true
		e.last = c
	}
	d.mu.Unlock()
	if !ok {
		return nil, rpc.Errorf(protocol.UnknownSession, "no session %q", p.SessionID)
	}
	if err := e.s.PromptIn(p.PermissionMode, p.Text); err != nil {
		if errors.Is(err, session.ErrBusy) {
			return nil, rpc.Errorf(protocol.SessionBusy, "%s", err.Error())
		}
		return nil, rpc.Errorf(protocol.ClaudeUnavailable, "%s", err.Error())
	}
	d.mu.Lock()
	if d.idle != nil {
		d.idle.Stop()
	}
	d.mu.Unlock()
	return map[string]bool{"ok": true}, nil
}

// lookup finds the session named by params' sessionId, storing the id in idOut.
func (d *Daemon) lookup(params json.RawMessage, idOut *string) (*sessionEntry, error) {
	var p struct {
		SessionID string `json:"sessionId"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.SessionID == "" {
		return nil, rpc.Errorf(protocol.InvalidParams, "a sessionId is required")
	}
	d.mu.Lock()
	e, ok := d.sessions[p.SessionID]
	d.mu.Unlock()
	if !ok {
		return nil, rpc.Errorf(protocol.UnknownSession, "no session %q", p.SessionID)
	}
	if idOut != nil {
		*idOut = p.SessionID
	}
	return e, nil
}

// broadcast sends a session update to the clients that follow the session.
func (d *Daemon) broadcast(id string, u session.Update) {
	d.mu.Lock()
	e, ok := d.sessions[id]
	var subs []*client
	if ok {
		for c := range e.subs {
			subs = append(subs, c)
		}
	}
	d.mu.Unlock()
	for _, c := range subs {
		_ = c.conn.Notify("session/update", map[string]any{"sessionId": id, "update": u})
	}
}

func newSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40 // version 4
	b[8] = b[8]&0x3f | 0x80 // RFC 4122 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// defaultHelperPath is the executable Claude Code runs as "claude-paird mcp".
// On Linux it is /proc/PID/exe, which stays this daemon's own binary even
// after an upgrade or a rebuild replaces the file, so a helper always speaks
// the daemon's protocol. Elsewhere it is the executable's path.
func defaultHelperPath() string {
	if runtime.GOOS == "linux" {
		self := fmt.Sprintf("/proc/%d/exe", os.Getpid())
		if _, err := os.Stat(self); err == nil {
			return self
		}
	}
	exe, _ := os.Executable()
	return exe
}

// emacsClientsLocked counts connected clients other than MCP helpers.
func (d *Daemon) emacsClientsLocked() int {
	n := 0
	for _, c := range d.clients {
		if !c.helper() {
			n++
		}
	}
	return n
}

// armIdle starts the idle timer when no client is connected and no turn runs.
func (d *Daemon) armIdle() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.opts.IdleTimeout <= 0 || d.emacsClientsLocked() > 0 || d.stopping {
		return
	}
	for _, e := range d.sessions {
		if e.s.Busy() {
			return
		}
	}
	if d.idle != nil {
		d.idle.Stop()
	}
	d.idle = time.AfterFunc(d.opts.IdleTimeout, func() { d.Stop("idle") })
}

// PrepareSocketDir makes sure dir exists, belongs to us and is private. A
// directory we create gets mode 0700. An existing one that others can reach
// is refused, never chmod-ed, because the user may share it on purpose.
func PrepareSocketDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return &UnsafeDirError{dir + " is not a directory"}
	}
	return checkPrivate(dir, info)
}

// CanConnect reports whether something accepts connections on path, a
// socket or an endpoint file.
func CanConnect(path string, timeout time.Duration) bool {
	nc, _, err := endpoint.Dial(path, timeout)
	if err != nil {
		return false
	}
	nc.Close()
	return true
}

func clearStaleSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&fs.ModeSocket == 0 {
		return fmt.Errorf("%s exists and is not a socket; refusing to replace it", path)
	}
	if CanConnect(path, time.Second) {
		return &AlreadyRunningError{Path: path}
	}
	return os.Remove(path)
}

func inodeOf(path string) (uint64, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, err
	}
	return inodeNumber(info), nil
}

func removeSocketIfOurs(path string, inode uint64) error {
	current, err := inodeOf(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if inode != 0 && current != inode {
		return nil // another daemon took over the path; leave its socket alone
	}
	err = os.Remove(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}
