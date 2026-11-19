package framing

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"testing/iotest"
)

const sample = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"text":"héllo wörld 🌍 ✓"}}`

func readAll(t *testing.T, r io.Reader) []string {
	t.Helper()
	fr := NewReader(r)
	var out []string
	for {
		body, err := fr.Read()
		if errors.Is(err, io.EOF) {
			return out
		}
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		out = append(out, string(body))
	}
}

func TestRoundTrip(t *testing.T) {
	got := readAll(t, bytes.NewReader(Frame([]byte(sample))))
	if len(got) != 1 || got[0] != sample {
		t.Fatalf("got %q", got)
	}
}

func TestContentLengthCountsBytes(t *testing.T) {
	frame := string(Frame([]byte(`{"s":"🌍é"}`)))
	want := fmt.Sprintf("Content-Length: %d\r\n", len(`{"s":"🌍é"}`))
	if !strings.HasPrefix(frame, want) || len(`{"s":"🌍é"}`) == len([]rune(`{"s":"🌍é"}`)) {
		t.Fatalf("frame %q does not start with %q", frame, want)
	}
}

func TestOneByteAtATime(t *testing.T) {
	got := readAll(t, iotest.OneByteReader(bytes.NewReader(Frame([]byte(sample)))))
	if len(got) != 1 || got[0] != sample {
		t.Fatalf("got %q", got)
	}
}

func TestEverySplitPoint(t *testing.T) {
	frame := Frame([]byte(sample))
	for i := 1; i < len(frame); i++ {
		r := io.MultiReader(bytes.NewReader(frame[:i]), bytes.NewReader(frame[i:]))
		if got := readAll(t, iotest.HalfReader(r)); len(got) != 1 || got[0] != sample {
			t.Fatalf("split at %d: got %q", i, got)
		}
	}
}

func TestSeveralMessagesInOneChunk(t *testing.T) {
	msgs := []string{`{"a":1}`, `{"b":"ü"}`, `{"c":[]}`}
	var buf bytes.Buffer
	for _, m := range msgs {
		buf.Write(Frame([]byte(m)))
	}
	got := readAll(t, &buf)
	if strings.Join(got, "|") != strings.Join(msgs, "|") {
		t.Fatalf("got %q", got)
	}
}

func TestOtherHeadersAndCase(t *testing.T) {
	got := readAll(t, strings.NewReader("Content-Type: application/json\r\ncontent-length: 2\r\n\r\n{}"))
	if len(got) != 1 || got[0] != "{}" {
		t.Fatalf("got %q", got)
	}
}

func TestFramingErrors(t *testing.T) {
	cases := map[string]string{
		"missing Content-Length":     "Foo: bar\r\n\r\n{}",
		"non-numeric Content-Length": "Content-Length: 12a\r\n\r\n",
		"negative Content-Length":    "Content-Length: -1\r\n\r\n",
		"line without a colon":       "garbage\r\n\r\n",
		"line without CR":            "Content-Length: 2\n\n{}",
		"endless header section":     strings.Repeat("a", 5000),
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := NewReader(strings.NewReader(input)).Read()
			var fe *Error
			if !errors.As(err, &fe) {
				t.Fatalf("got %v, want a framing error", err)
			}
		})
	}
}

func TestBodyOverLimit(t *testing.T) {
	r := NewReader(strings.NewReader("Content-Length: 11\r\n\r\n"))
	r.MaxBody = 10
	var fe *Error
	if _, err := r.Read(); !errors.As(err, &fe) {
		t.Fatalf("got %v, want a framing error", err)
	}
}

func TestEndOfStream(t *testing.T) {
	if _, err := NewReader(strings.NewReader("")).Read(); !errors.Is(err, io.EOF) {
		t.Fatalf("empty stream: got %v, want io.EOF", err)
	}
	if _, err := NewReader(strings.NewReader("Content-Length: 5\r\n\r\n{}")).Read(); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("truncated body: got %v, want io.ErrUnexpectedEOF", err)
	}
	if _, err := NewReader(strings.NewReader("Content-Len")).Read(); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("truncated header: got %v, want io.ErrUnexpectedEOF", err)
	}
}
