package server

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/victory/tandem/daemon/internal/protocol"
	"github.com/victory/tandem/daemon/internal/rpc"
	"github.com/victory/tandem/daemon/internal/suggest"
)

// maxSuggestContext is the most code a suggestion request may carry on
// each side of the cursor.
const maxSuggestContext = 64 << 10

type suggestParams struct {
	ClaudePath string             `json:"claudePath"`
	Model      string             `json:"model"`
	Env        map[string]*string `json:"env"`
	// Token is the client's name for the request, sent back with each
	// suggest/text notification.
	Token    json.RawMessage `json:"token"`
	File     string          `json:"file"`
	Language string          `json:"language"`
	Prefix   string          `json:"prefix"`
	Suffix   string          `json:"suffix"`
}

// suggestions returns the daemon's Suggester, made on first use with an
// empty directory for claude to run in.
func (d *Daemon) suggestions() (*suggest.Suggester, error) {
	d.suggestMu.Lock()
	defer d.suggestMu.Unlock()
	if d.suggester == nil {
		dir, err := os.MkdirTemp("", "tandemd-suggest-")
		if err != nil {
			return nil, err
		}
		d.suggestDir = dir
		d.suggester = suggest.New(suggest.Options{Dir: dir, Log: d.opts.Log})
	}
	return d.suggester, nil
}

func (d *Daemon) stopSuggestions() {
	d.suggestMu.Lock()
	defer d.suggestMu.Unlock()
	if d.suggester != nil {
		d.suggester.Close()
		_ = os.RemoveAll(d.suggestDir)
		d.suggester, d.suggestDir = nil, ""
	}
}

// suggest answers suggest/complete: the text to insert at the cursor,
// streamed to the client as suggest/text notifications on the way.
func (d *Daemon) suggest(ctx context.Context, c *client, params json.RawMessage) (any, error) {
	var p suggestParams
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.ClaudePath == "" {
		return nil, rpc.Errorf(protocol.InvalidParams, "suggest/complete needs claudePath, prefix and suffix")
	}
	for name := range p.Env {
		if name == "" || strings.ContainsAny(name, "=\x00") {
			return nil, rpc.Errorf(protocol.InvalidParams, "env has a bad variable name %q", name)
		}
	}
	if len(p.Prefix) > maxSuggestContext || len(p.Suffix) > maxSuggestContext {
		return nil, rpc.Errorf(protocol.InvalidParams, "prefix and suffix may hold at most %d bytes each", maxSuggestContext)
	}
	s, err := d.suggestions()
	if err != nil {
		return nil, rpc.Errorf(protocol.InternalError, "%s", err.Error())
	}
	token := p.Token
	if len(token) == 0 {
		token = json.RawMessage("null")
	}
	text, err := s.Complete(ctx,
		suggest.Config{ClaudePath: p.ClaudePath, Model: p.Model, Env: p.Env},
		suggest.Request{File: p.File, Language: p.Language, Prefix: p.Prefix, Suffix: p.Suffix},
		func(text string) {
			_ = c.conn.Notify("suggest/text", map[string]any{"token": token, "text": text})
		})
	switch {
	case errors.Is(err, suggest.ErrSuperseded) || errors.Is(err, suggest.ErrCancelled):
		return nil, rpc.Errorf(protocol.Superseded, "%s", err.Error())
	case err != nil:
		return nil, rpc.Errorf(protocol.ClaudeUnavailable, "%s", err.Error())
	}
	return map[string]any{"token": token, "text": text}, nil
}

func (d *Daemon) cancelSuggestion() (any, error) {
	d.suggestMu.Lock()
	s := d.suggester
	d.suggestMu.Unlock()
	return map[string]bool{"cancelled": s != nil && s.Cancel()}, nil
}
