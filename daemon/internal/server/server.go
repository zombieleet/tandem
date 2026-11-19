// Package server is the daemon: a Unix socket server speaking the claude-pair protocol.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/victory/claude-pair/daemon/internal/paths"
	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/rpc"
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
}

type client struct {
	conn        *rpc.Conn
	initialized atomic.Bool
	name        atomic.Value // string
}

// Daemon serves clients on a Unix socket.
type Daemon struct {
	opts    Options
	ln      *net.UnixListener
	inode   uint64
	started time.Time
	wg      sync.WaitGroup

	mu         sync.Mutex
	clients    map[int]*client
	nextClient int
	idle       *time.Timer
	stopping   bool
	reason     string

	stopOnce sync.Once
	done     chan struct{}
}

// New returns a Daemon; call Start to listen.
func New(opts Options) *Daemon {
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	return &Daemon{opts: opts, clients: map[int]*client{}, done: make(chan struct{})}
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
		d.mu.Unlock()

		d.opts.Log.Info("stopping", "reason", reason)
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
		if err := removeSocketIfOurs(d.opts.SocketPath, d.inode); err != nil {
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
	clients := len(d.clients)
	d.mu.Unlock()
	return protocol.StatusResult{
		Version:            d.opts.Version,
		ProtocolVersion:    protocol.Version,
		PID:                os.Getpid(),
		UptimeSeconds:      int(math.Round(time.Since(d.started).Seconds())),
		Clients:            clients,
		Sessions:           0,
		SocketPath:         d.opts.SocketPath,
		IdleTimeoutSeconds: d.opts.IdleTimeout.Seconds(),
	}
}

func (d *Daemon) acceptLoop() {
	for {
		nc, err := d.ln.AcceptUnix()
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

func (d *Daemon) accept(nc *net.UnixConn) {
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
		return d.handle(c, method, params)
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
		d.mu.Unlock()
		d.opts.Log.Debug("client disconnected", "client", id, "name", c.name.Load())
		d.armIdle()
	}()
}

func (d *Daemon) handle(c *client, method string, params json.RawMessage) (any, error) {
	if method == "initialize" {
		return d.initialize(c, params)
	}
	if !c.initialized.Load() {
		return nil, rpc.Errorf(protocol.NotInitialized, "send initialize before %s", method)
	}
	switch method {
	case "daemon/status":
		return d.Status(), nil
	case "shutdown":
		return rpc.Then{
			Result: map[string]bool{"ok": true},
			After:  func() { go d.Stop("shutdown request") },
		}, nil
	default:
		return nil, rpc.Errorf(protocol.MethodNotFound, "unknown method %s", method)
	}
}

func (d *Daemon) initialize(c *client, params json.RawMessage) (any, error) {
	var p protocol.InitializeParams
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.ProtocolVersion == nil {
		return nil, rpc.Errorf(protocol.InvalidParams, "initialize needs a protocolVersion string")
	}
	if !protocol.Compatible(*p.ProtocolVersion, protocol.Version) {
		return nil, &rpc.Error{
			Code: protocol.IncompatibleProtocol,
			Message: fmt.Sprintf("client protocol %s is not compatible with daemon protocol %s",
				*p.ProtocolVersion, protocol.Version),
			Data: map[string]string{"daemonProtocolVersion": protocol.Version, "daemonVersion": d.opts.Version},
		}
	}
	c.initialized.Store(true)
	if p.ClientInfo != nil {
		c.name.Store(p.ClientInfo.Name)
	}
	d.opts.Log.Info("client initialized", "client", c.conn.ID, "name", c.name.Load())
	return protocol.InitializeResult{
		ProtocolVersion: protocol.Version,
		ServerInfo:      protocol.ServerInfo{Name: "claude-paird", Version: d.opts.Version},
		PID:             os.Getpid(),
		Capabilities:    map[string]any{},
	}, nil
}

func (d *Daemon) armIdle() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.opts.IdleTimeout <= 0 || len(d.clients) > 0 || d.stopping {
		return
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
	if st, ok := info.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return &UnsafeDirError{fmt.Sprintf("%s belongs to uid %d, not to you (uid %d)", dir, st.Uid, os.Getuid())}
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return &UnsafeDirError{fmt.Sprintf(
			"%s has mode %o, so other users can reach the socket; run chmod 700 on it or pick another directory", dir, perm)}
	}
	return nil
}

// CanConnect reports whether something accepts connections on path.
func CanConnect(path string, timeout time.Duration) bool {
	nc, err := net.DialTimeout("unix", path, timeout)
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
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Ino), nil
	}
	return 0, nil
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
