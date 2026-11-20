package rpc

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"testing"
	"time"
)

// pair connects two Conns over an in-memory pipe.
func pair(t *testing.T, serverHandle Handler) (client, server *Conn) {
	t.Helper()
	a, b := net.Pipe()
	log := slog.New(slog.DiscardHandler)
	none := func(context.Context, *Conn, string, json.RawMessage) (any, error) {
		return nil, Errorf(-32601, "no methods")
	}
	client = New(1, a, none, nil, log)
	server = New(2, b, serverHandle, nil, log)
	go client.Serve()
	go server.Serve()
	t.Cleanup(func() { a.Close(); b.Close() })
	return client, server
}

func TestCallAndReply(t *testing.T) {
	client, _ := pair(t, func(_ context.Context, _ *Conn, method string, params json.RawMessage) (any, error) {
		return map[string]string{"echo": method + string(params)}, nil
	})
	got, err := client.Call(context.Background(), "ping", []int{1})
	if err != nil || string(got) != `{"echo":"ping[1]"}` {
		t.Fatalf("got %s, %v", got, err)
	}
}

func TestCancellingACallCancelsTheHandler(t *testing.T) {
	cancelled := make(chan error, 1)
	client, _ := pair(t, func(ctx context.Context, _ *Conn, _ string, _ json.RawMessage) (any, error) {
		<-ctx.Done()
		cancelled <- ctx.Err()
		return "too late", nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	errc := make(chan error, 1)
	go func() {
		_, err := client.Call(ctx, "wait", nil)
		errc <- err
	}()
	time.Sleep(50 * time.Millisecond)
	cancel()
	if err := <-errc; !errors.Is(err, context.Canceled) {
		t.Fatalf("Call returned %v, want context.Canceled", err)
	}
	select {
	case err := <-cancelled:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("handler saw %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the handler was not cancelled")
	}
}

func TestClosingTheConnectionCancelsHandlers(t *testing.T) {
	cancelled := make(chan struct{})
	client, _ := pair(t, func(ctx context.Context, _ *Conn, _ string, _ json.RawMessage) (any, error) {
		<-ctx.Done()
		close(cancelled)
		return nil, ctx.Err()
	})
	go client.Call(context.Background(), "wait", nil)
	time.Sleep(50 * time.Millisecond)
	client.nc.Close()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("closing the connection did not cancel the handler")
	}
}

func TestErrorsKeepTheirCode(t *testing.T) {
	client, _ := pair(t, func(context.Context, *Conn, string, json.RawMessage) (any, error) {
		return nil, &Error{Code: -32004, Message: "no session", Data: map[string]int{"n": 1}}
	})
	_, err := client.Call(context.Background(), "x", nil)
	var re *Error
	if !errors.As(err, &re) || re.Code != -32004 || re.Message != "no session" {
		t.Fatalf("got %v", err)
	}
}
