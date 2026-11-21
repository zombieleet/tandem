// Package endpoint connects to claude-paird, on a Unix socket or, where
// Emacs has none (Windows), on a local TCP port.
//
// A TCP daemon writes an endpoint file where the socket would be: JSON with
// the port, a token and its process id, readable only by the user. A client
// tells the two apart by what is at the path, and sends the token in
// initialize; the daemon refuses a connection without it.
package endpoint

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Info is the content of an endpoint file.
type Info struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

// IsFile reports whether path holds an endpoint file rather than a socket.
func IsFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// Read returns the endpoint file at path.
func Read(path string) (Info, error) {
	var info Info
	data, err := os.ReadFile(path)
	if err != nil {
		return info, err
	}
	if err := json.Unmarshal(data, &info); err != nil || info.Port <= 0 || info.Token == "" {
		return info, fmt.Errorf("%s is not a claude-paird endpoint file", path)
	}
	return info, nil
}

// Write replaces the endpoint file at path with info, readable only by the
// user. It never leaves a half-written file behind.
func Write(path string, info Info) error {
	data, _ := json.Marshal(info)
	tmp, err := os.CreateTemp(filepath.Dir(path), ".endpoint-*")
	if err != nil {
		return err
	}
	_ = tmp.Chmod(0o600)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// NewToken returns a random secret for an endpoint file.
func NewToken() string {
	var b [32]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Address returns the TCP address of a port on this machine only.
func Address(port int) string {
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
}

// Dial connects to the daemon at path, a socket or an endpoint file. It
// returns the token to send in initialize, "" for a socket.
func Dial(path string, timeout time.Duration) (net.Conn, string, error) {
	if !IsFile(path) {
		nc, err := net.DialTimeout("unix", path, timeout)
		return nc, "", err
	}
	info, err := Read(path)
	if err != nil {
		return nil, "", err
	}
	nc, err := net.DialTimeout("tcp", Address(info.Port), timeout)
	return nc, info.Token, err
}
