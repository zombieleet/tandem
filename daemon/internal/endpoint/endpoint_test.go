package endpoint

import (
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestWriteReadDial(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.json")
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	token := NewToken()
	if len(token) != 64 {
		t.Fatalf("token %q", token)
	}
	if err := Write(path, Info{Port: ln.Addr().(*net.TCPAddr).Port, Token: token, PID: 7}); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(path); runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", info.Mode().Perm())
	}
	if !IsFile(path) {
		t.Fatal("not seen as an endpoint file")
	}
	nc, got, err := Dial(path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	nc.Close()
	if got != token {
		t.Fatalf("token %q", got)
	}
	os.WriteFile(path, []byte("{}"), 0o600)
	if _, _, err := Dial(path, time.Second); err == nil {
		t.Fatal("a bad endpoint file was accepted")
	}
	if IsFile(filepath.Join(dir, "missing")) {
		t.Fatal("a missing file is an endpoint file")
	}
}
