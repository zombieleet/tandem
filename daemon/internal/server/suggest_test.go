package server

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/victory/tandem/daemon/internal/protocol"
)

func TestSuggestions(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	m := c.request("suggest/complete", map[string]any{"claudePath": fakeClaude, "token": 7,
		"file": "a.py", "language": "python", "prefix": "x = fake-suggest:42<", "suffix": "\n"})
	wantOK(t, m)
	var r struct {
		Token int
		Text  string
	}
	json.Unmarshal(m.Result, &r)
	if r.Token != 7 || r.Text != "42" {
		t.Fatalf("result %s", m.Result)
	}
	// The text on its way, with the client's token.
	seen := 0
	for _, n := range c.notes {
		var p struct {
			Token int
			Text  string
		}
		json.Unmarshal(n.Params, &p)
		if n.Method == "suggest/text" && p.Token == 7 {
			seen++
		}
	}
	if seen == 0 {
		t.Fatalf("no suggest/text notification: %+v", c.notes)
	}
	wantCode(t, c.request("suggest/complete", map[string]any{"prefix": "x"}), protocol.InvalidParams)
	wantCode(t, c.request("suggest/complete", map[string]any{"claudePath": fakeClaude,
		"env": map[string]string{"A=B": "c"}}), protocol.InvalidParams)
	big := make([]byte, 70<<10)
	wantCode(t, c.request("suggest/complete", map[string]any{"claudePath": fakeClaude,
		"prefix": string(big)}), protocol.InvalidParams)

	// The daemon's directory for them goes when it stops.
	d.suggestMu.Lock()
	dir := d.suggestDir
	d.suggestMu.Unlock()
	if !exists(dir) {
		t.Fatalf("no directory %q", dir)
	}
	d.Stop("test")
	if exists(dir) {
		t.Fatalf("%s is still there", dir)
	}
}

func TestNewerSuggestionSupersedes(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := ready(t, d)
	wantOK(t, c.request("suggest/cancel", nil))
	c.send(map[string]any{"jsonrpc": "2.0", "id": 100, "method": "suggest/complete",
		"params": map[string]any{"claudePath": fakeClaude, "prefix": "fake-suggest:slow:old<"}})
	waitFor(t, "the first suggestion to start", func() bool {
		d.suggestMu.Lock()
		defer d.suggestMu.Unlock()
		return d.suggester != nil
	})
	time.Sleep(300 * time.Millisecond) // until it runs; it takes two seconds
	c.send(map[string]any{"jsonrpc": "2.0", "id": 101, "method": "suggest/complete",
		"params": map[string]any{"claudePath": fakeClaude, "prefix": "fake-suggest:new<"}})
	got := map[string]message{}
	for len(got) < 2 {
		m := c.read()
		if len(m.ID) > 0 {
			got[string(m.ID)] = m
		}
	}
	wantCode(t, got["100"], protocol.Superseded)
	wantOK(t, got["101"])
	var r struct{ Text string }
	json.Unmarshal(got["101"].Result, &r)
	if r.Text != "new" {
		t.Fatalf("got %q", r.Text)
	}
}
