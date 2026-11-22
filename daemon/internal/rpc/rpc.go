// Package rpc is JSON-RPC 2.0 over a framed stream. Either side may send
// requests: the client calls the daemon, and the daemon calls the client.
package rpc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/victory/tandem/daemon/internal/framing"
	"github.com/victory/tandem/daemon/internal/protocol"
)

// Error is a JSON-RPC error object. Handlers return one to choose the code.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *Error) Error() string { return e.Message }

// Errorf builds an *Error with a formatted message.
func Errorf(code int, format string, a ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, a...)}
}

// ErrClosed is returned by calls on a closed connection.
var ErrClosed = errors.New("connection closed")

// RequestCancelled is the error code for a request the peer cancelled with
// $/cancelRequest, as in the Language Server Protocol.
const RequestCancelled = -32800

// cancelMethod is the notification either side sends to cancel a request.
const cancelMethod = "$/cancelRequest"

// Then is a handler result that runs After once the reply has been written.
type Then struct {
	Result any
	After  func()
}

// Handler answers requests. It runs on its own goroutine per request.
type Handler func(ctx context.Context, c *Conn, method string, params json.RawMessage) (any, error)

// NotificationHandler receives notifications, in order, on the read goroutine.
type NotificationHandler func(c *Conn, method string, params json.RawMessage)

// closeGrace is how long Close waits for the peer before dropping the socket.
const closeGrace = 500 * time.Millisecond

// Conn is one JSON-RPC connection.
type Conn struct {
	ID      int
	nc      net.Conn
	reader  *framing.Reader
	log     *slog.Logger
	handle  Handler
	notify  NotificationHandler
	ctx     context.Context
	cancel  context.CancelFunc
	writeMu sync.Mutex

	mu      sync.Mutex
	pending map[string]chan reply
	cancels map[string]context.CancelFunc // running handlers, by request id
	nextID  int64

	closing  sync.Once
	finished sync.Once
	done     chan struct{}
	inFlight sync.WaitGroup
}

type reply struct {
	result json.RawMessage
	err    *Error
}

// New wraps nc. Call Serve to start reading.
func New(id int, nc net.Conn, handle Handler, notify NotificationHandler, log *slog.Logger) *Conn {
	ctx, cancel := context.WithCancel(context.Background())
	if notify == nil {
		notify = func(*Conn, string, json.RawMessage) {}
	}
	return &Conn{
		ID:      id,
		nc:      nc,
		reader:  framing.NewReader(nc),
		log:     log.With("client", id),
		handle:  handle,
		notify:  notify,
		ctx:     ctx,
		cancel:  cancel,
		pending: map[string]chan reply{},
		cancels: map[string]context.CancelFunc{},
		done:    make(chan struct{}),
	}
}

// Done is closed once the connection is fully closed.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Serve reads and dispatches messages until the peer goes away or the framing
// breaks, then closes the connection and waits for running handlers.
func (c *Conn) Serve() {
	defer c.finish()
	for {
		body, err := c.reader.Read()
		if err != nil {
			var fe *framing.Error
			if errors.As(err, &fe) {
				c.log.Warn("framing error, closing connection", "error", fe.Error())
				c.sendError(nil, protocol.ParseError, fe.Error())
				c.Close()
				// The stream cannot be parsed any more; wait for the peer, or
				// the grace timer, to close it.
				_, _ = io.Copy(io.Discard, c.nc)
				return
			}
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				c.log.Debug("read ended", "error", err)
			}
			return
		}
		c.dispatch(body)
	}
}

// Call sends a request to the peer and waits for the reply.
func (c *Conn) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	key := strconv.FormatInt(id, 10)
	ch := make(chan reply, 1)
	c.pending[key] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, key)
		c.mu.Unlock()
	}()
	if err := c.send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
		return nil, err
	}
	select {
	case r := <-ch:
		if r.err != nil {
			return nil, r.err
		}
		return r.result, nil
	case <-ctx.Done():
		_ = c.Notify(cancelMethod, map[string]int64{"id": id})
		return nil, ctx.Err()
	case <-c.done:
		return nil, ErrClosed
	}
}

// Notify sends a notification to the peer.
func (c *Conn) Notify(method string, params any) error {
	return c.send(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}

// Close flushes pending output and half-closes the socket, so the peer reads
// everything sent so far. The socket is dropped if the peer lingers.
func (c *Conn) Close() {
	c.closing.Do(func() {
		c.writeMu.Lock()
		defer c.writeMu.Unlock()
		if uc, ok := c.nc.(*net.UnixConn); ok {
			_ = uc.CloseWrite()
		} else {
			_ = c.nc.Close()
		}
		time.AfterFunc(closeGrace, func() { _ = c.nc.Close() })
	})
}

func (c *Conn) finish() {
	c.finished.Do(func() {
		_ = c.nc.Close()
		c.cancel()
		close(c.done)
		c.inFlight.Wait()
	})
}

func (c *Conn) send(message any) error {
	body, err := json.Marshal(message)
	if err != nil {
		return err
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	select {
	case <-c.done:
		return ErrClosed
	default:
	}
	if _, err := c.nc.Write(framing.Frame(body)); err != nil {
		c.log.Debug("write failed", "error", err)
		_ = c.nc.Close()
		return ErrClosed
	}
	return nil
}

var nullID = json.RawMessage("null")

func (c *Conn) sendError(id json.RawMessage, code int, message string) {
	if id == nil {
		id = nullID
	}
	_ = c.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": &Error{Code: code, Message: message}})
}

func (c *Conn) invalid(id json.RawMessage, reason string) {
	c.log.Warn("invalid request", "reason", reason)
	c.sendError(id, protocol.InvalidRequest, reason)
}

func validID(raw json.RawMessage) bool {
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return false
	}
	switch v.(type) {
	case string, float64:
		return true
	}
	return false
}

func (c *Conn) dispatch(body []byte) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		if !json.Valid(body) {
			c.log.Warn("invalid JSON", "error", err)
			c.sendError(nil, protocol.ParseError, "invalid JSON: "+err.Error())
		} else {
			c.invalid(nil, "not a JSON-RPC 2.0 message")
		}
		return
	}
	var version string
	if raw, ok := fields["jsonrpc"]; !ok || json.Unmarshal(raw, &version) != nil || version != "2.0" {
		c.invalid(nil, "not a JSON-RPC 2.0 message")
		return
	}
	rawID, hasID := fields["id"]
	idOK := hasID && validID(rawID)
	var replyID json.RawMessage
	if idOK {
		replyID = rawID
	}

	if rawMethod, ok := fields["method"]; ok {
		var method string
		if json.Unmarshal(rawMethod, &method) != nil {
			c.invalid(replyID, "method must be a string")
			return
		}
		params := fields["params"]
		if !hasID {
			c.runNotification(method, params)
			return
		}
		if !idOK {
			c.invalid(nil, "request id must be a number or a string")
			return
		}
		c.inFlight.Add(1)
		go func() {
			defer c.inFlight.Done()
			c.answer(rawID, method, params)
		}()
		return
	}

	_, hasResult := fields["result"]
	rawError, hasError := fields["error"]
	if idOK && (hasResult || hasError) {
		c.settle(rawID, fields["result"], rawError, hasError)
		return
	}
	c.invalid(replyID, "message is neither a request, a notification nor a response")
}

func (c *Conn) runNotification(method string, params json.RawMessage) {
	if method == cancelMethod {
		var p struct {
			ID json.RawMessage `json:"id"`
		}
		if json.Unmarshal(params, &p) == nil && len(p.ID) > 0 {
			c.mu.Lock()
			cancel := c.cancels[string(bytes.TrimSpace(p.ID))]
			c.mu.Unlock()
			if cancel != nil {
				cancel()
			}
		}
		return
	}
	defer func() {
		if r := recover(); r != nil {
			c.log.Error("notification handler panicked", "method", method, "panic", r)
		}
	}()
	c.notify(c, method, params)
}

func (c *Conn) answer(id json.RawMessage, method string, params json.RawMessage) {
	defer func() {
		if r := recover(); r != nil {
			c.log.Error("request handler panicked", "method", method, "panic", r)
			c.sendError(id, protocol.InternalError, fmt.Sprint(r))
		}
	}()
	key := string(bytes.TrimSpace(id))
	ctx, cancel := context.WithCancel(c.ctx)
	c.mu.Lock()
	c.cancels[key] = cancel
	c.mu.Unlock()
	defer func() {
		cancel()
		c.mu.Lock()
		delete(c.cancels, key)
		c.mu.Unlock()
	}()
	result, err := c.handle(ctx, c, method, params)
	if err == nil && ctx.Err() != nil && c.ctx.Err() == nil {
		err = &Error{Code: RequestCancelled, Message: "request cancelled"}
	}
	if err != nil {
		var re *Error
		if !errors.As(err, &re) {
			c.log.Error("request handler failed", "method", method, "error", err)
			re = &Error{Code: protocol.InternalError, Message: err.Error()}
		}
		_ = c.send(map[string]any{"jsonrpc": "2.0", "id": id, "error": re})
		return
	}
	var after func()
	if t, ok := result.(Then); ok {
		result, after = t.Result, t.After
	}
	_ = c.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	if after != nil {
		after()
	}
}

func (c *Conn) settle(rawID, result, rawError json.RawMessage, hasError bool) {
	key := string(bytes.TrimSpace(rawID))
	c.mu.Lock()
	ch, ok := c.pending[key]
	c.mu.Unlock()
	if !ok {
		c.log.Warn("reply to an unknown request", "id", key)
		return
	}
	r := reply{result: result}
	if hasError && string(bytes.TrimSpace(rawError)) != "null" {
		var e Error
		if json.Unmarshal(rawError, &e) != nil {
			e = Error{Code: protocol.InternalError, Message: "malformed error object"}
		}
		r.err = &e
	}
	ch <- r
}
