// Package framing reads and writes Content-Length framed messages, as in the
// Language Server Protocol.
package framing

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	maxHeaderBytes = 4096
	// DefaultMaxBody is the largest body a Reader accepts unless told otherwise.
	DefaultMaxBody = 64 << 20
)

// Error is a framing error. The stream cannot be resynchronized after one,
// so the connection must close.
type Error struct{ msg string }

func (e *Error) Error() string { return e.msg }

func errorf(format string, a ...any) *Error { return &Error{fmt.Sprintf(format, a...)} }

// Reader reads framed message bodies.
type Reader struct {
	br      *bufio.Reader
	MaxBody int
}

// NewReader returns a Reader on r.
func NewReader(r io.Reader) *Reader {
	return &Reader{br: bufio.NewReaderSize(r, maxHeaderBytes), MaxBody: DefaultMaxBody}
}

// Read returns the next message body. It returns io.EOF when the stream ends
// between messages, io.ErrUnexpectedEOF when it ends inside one, and *Error
// for malformed framing.
func (r *Reader) Read() ([]byte, error) {
	length := -1
	headerBytes := 0
	for first := true; ; first = false {
		line, err := r.br.ReadSlice('\n')
		if err != nil {
			switch {
			case errors.Is(err, bufio.ErrBufferFull):
				return nil, errorf("header section is longer than %d bytes", maxHeaderBytes)
			case errors.Is(err, io.EOF) && first && len(line) == 0:
				return nil, io.EOF
			case errors.Is(err, io.EOF):
				return nil, io.ErrUnexpectedEOF
			default:
				return nil, err
			}
		}
		headerBytes += len(line)
		if headerBytes > maxHeaderBytes {
			return nil, errorf("header section is longer than %d bytes", maxHeaderBytes)
		}
		if !bytes.HasSuffix(line, []byte("\r\n")) {
			return nil, errorf("header line %q does not end with CRLF", line)
		}
		text := string(line[:len(line)-2])
		if text == "" {
			break
		}
		name, value, ok := strings.Cut(text, ":")
		if !ok || strings.TrimSpace(name) == "" {
			return nil, errorf("malformed header line %q", text)
		}
		if strings.EqualFold(strings.TrimSpace(name), "Content-Length") {
			value = strings.TrimSpace(value)
			n, err := strconv.Atoi(value)
			if err != nil || value == "" || strings.TrimLeft(value, "0123456789") != "" {
				return nil, errorf("invalid Content-Length %q", value)
			}
			length = n
		}
	}
	if length < 0 {
		return nil, errorf("missing Content-Length header")
	}
	if length > r.MaxBody {
		return nil, errorf("message of %d bytes exceeds the %d byte limit", length, r.MaxBody)
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r.br, body); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return body, nil
}

// Frame returns body with its header, ready to write in one call.
func Frame(body []byte) []byte {
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))
	out := make([]byte, 0, len(header)+len(body))
	return append(append(out, header...), body...)
}
