package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/victory/tandem/daemon/internal/endpoint"
	"github.com/victory/tandem/daemon/internal/framing"
	"github.com/victory/tandem/daemon/internal/protocol"
)

// privateDir makes a fresh 0700 directory under the system temp dir. It avoids
// t.TempDir, whose long names can exceed the socket path limit.
func privateDir(t *testing.T, prefix string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// overTCP runs the tests on a TCP daemon, cancelling turns by message, as
// on Windows: CPD_TEST_TCP=1.
var overTCP = os.Getenv("CPD_TEST_TCP") == "1"

// skipOverTCP skips a test about Unix sockets themselves.
func skipOverTCP(t *testing.T) {
	t.Helper()
	if overTCP || runtime.GOOS == "windows" {
		t.Skip("about Unix sockets and their modes")
	}
}

var (
	testDaemonsMu sync.Mutex
	testDaemons   = map[*testing.T][]*Daemon{}
)

// projectDir returns a new directory for a test's project, removed once the
// test's daemons have stopped: Windows refuses to delete a directory that a
// running claude works in.
func projectDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "cpd-project-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		testDaemonsMu.Lock()
		daemons := testDaemons[t]
		delete(testDaemons, t)
		testDaemonsMu.Unlock()
		for _, d := range daemons {
			d.Stop("test cleanup")
		}
		os.RemoveAll(dir)
	})
	return dir
}

func startDaemon(t *testing.T, idle time.Duration, prefix string) *Daemon {
	t.Helper()
	name := "d.sock"
	if overTCP {
		name = "d.json"
	}
	d := New(Options{
		SocketPath:         filepath.Join(privateDir(t, prefix), name),
		IdleTimeout:        idle,
		Version:            "9.9.9-test",
		HelperPath:         helperBinary,
		TCP:                overTCP,
		InterruptByMessage: overTCP,
	})
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Stop("test cleanup") })
	testDaemonsMu.Lock()
	testDaemons[t] = append(testDaemons[t], d)
	testDaemonsMu.Unlock()
	return d
}

type message struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	} `json:"error"`
}

type testClient struct {
	t      *testing.T
	nc     net.Conn
	reader *framing.Reader
	nextID int
	notes  []message // notifications read while waiting for a reply
	token  string    // for a TCP daemon
}

func connect(t *testing.T, path string) *testClient {
	t.Helper()
	nc, token, err := endpoint.Dial(path, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	return &testClient{t: t, nc: nc, reader: framing.NewReader(nc), token: token}
}

func (c *testClient) sendRaw(s string) {
	c.t.Helper()
	if _, err := io.WriteString(c.nc, s); err != nil {
		c.t.Fatal(err)
	}
}

func (c *testClient) send(v any) {
	c.t.Helper()
	body, _ := json.Marshal(v)
	c.sendRaw(string(framing.Frame(body)))
}

func (c *testClient) read() message {
	c.t.Helper()
	c.nc.SetReadDeadline(time.Now().Add(3 * time.Second))
	body, err := c.reader.Read()
	if err != nil {
		c.t.Fatalf("read: %v", err)
	}
	var m message
	if err := json.Unmarshal(body, &m); err != nil {
		c.t.Fatalf("bad reply %s: %v", body, err)
	}
	return m
}

func (c *testClient) request(method string, params any) message {
	c.t.Helper()
	c.nextID++
	c.send(map[string]any{"jsonrpc": "2.0", "id": c.nextID, "method": method, "params": params})
	for {
		m := c.read()
		if m.Method != "" && len(m.ID) == 0 {
			c.notes = append(c.notes, m)
			continue
		}
		if string(m.ID) != fmt.Sprint(c.nextID) {
			c.t.Fatalf("reply id %s, want %d", m.ID, c.nextID)
		}
		return m
	}
}

// note returns the next notification, reading one if none is buffered.
func (c *testClient) note() message {
	c.t.Helper()
	if len(c.notes) > 0 {
		m := c.notes[0]
		c.notes = c.notes[1:]
		return m
	}
	return c.read()
}

func (c *testClient) initialize(version string) message {
	return c.request("initialize", map[string]any{"protocolVersion": version, "clientInfo": map[string]string{"name": "test"},
		"token": c.token})
}

func wantCode(t *testing.T, m message, code int) {
	t.Helper()
	if m.Error == nil || m.Error.Code != code {
		t.Fatalf("got %+v, want error code %d", m, code)
	}
}

func wantOK(t *testing.T, m message) {
	t.Helper()
	if m.Error != nil {
		t.Fatalf("unexpected error %d %s", m.Error.Code, m.Error.Message)
	}
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestInitializeThenStatus(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	init := c.initialize(protocol.Version)
	wantOK(t, init)
	var result protocol.InitializeResult
	json.Unmarshal(init.Result, &result)
	if result.ProtocolVersion != protocol.Version || result.ServerInfo.Name != "tandemd" ||
		result.ServerInfo.Version != "9.9.9-test" || result.PID != os.Getpid() || result.Capabilities == nil {
		t.Fatalf("initialize result %s", init.Result)
	}
	if !strings.Contains(string(init.Result), `"capabilities":{}`) {
		t.Fatalf("capabilities must be an empty object: %s", init.Result)
	}
	status := c.request("daemon/status", nil)
	wantOK(t, status)
	var s protocol.StatusResult
	json.Unmarshal(status.Result, &s)
	if s.Clients != 1 || s.Sessions != 0 || s.Version != "9.9.9-test" || s.SocketPath != d.opts.SocketPath {
		t.Fatalf("status %s", status.Result)
	}
}

func TestRequestBeforeInitialize(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	wantCode(t, connect(t, d.opts.SocketPath).request("daemon/status", nil), protocol.NotInitialized)
}

func TestIncompatibleProtocol(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	cur, _ := protocol.ParseVersion(protocol.Version)
	incompatible := []string{
		fmt.Sprintf("%d.0.0", cur[0]+1),
		fmt.Sprintf("%d.%d.0", cur[0], cur[1]+1),
	}
	if cur[1] > 0 {
		incompatible = append(incompatible, fmt.Sprintf("%d.%d.0", cur[0], cur[1]-1))
	}
	for _, v := range incompatible {
		m := c.initialize(v)
		wantCode(t, m, protocol.IncompatibleProtocol)
		if !strings.Contains(m.Error.Message, v) || !strings.Contains(m.Error.Message, protocol.Version) {
			t.Fatalf("message %q should name both versions", m.Error.Message)
		}
		want := fmt.Sprintf(`{"daemonProtocolVersion":%q,"daemonVersion":"9.9.9-test","pid":%d}`, protocol.Version, os.Getpid())
		if string(m.Error.Data) != want {
			t.Fatalf("data %s, want %s", m.Error.Data, want)
		}
	}
	wantCode(t, c.request("daemon/status", nil), protocol.NotInitialized)
}

func TestInitializeInvalidParams(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	for _, params := range []any{map[string]any{}, map[string]any{"protocolVersion": 1}, []int{1}, nil} {
		wantCode(t, c.request("initialize", params), protocol.InvalidParams)
	}
}

func TestUnknownMethod(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	wantCode(t, c.request("no/such/method", nil), protocol.MethodNotFound)
}

func TestInvalidJSONKeepsTheConnection(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	c.sendRaw("Content-Length: 3\r\n\r\n{x}")
	m := c.read()
	wantCode(t, m, protocol.ParseError)
	if string(m.ID) != "null" {
		t.Fatalf("id %s, want null", m.ID)
	}
	wantOK(t, c.initialize(protocol.Version))
}

func TestNotJSONRPC(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	for _, v := range []any{map[string]string{"hello": "world"}, []int{1, 2}, map[string]any{"jsonrpc": "1.0", "id": 1, "method": "x"}} {
		c.send(v)
		wantCode(t, c.read(), protocol.InvalidRequest)
	}
}

func TestBrokenFramingClosesTheConnection(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	c.sendRaw("Content-Length: nope\r\n\r\n")
	wantCode(t, c.read(), protocol.ParseError)
	c.nc.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.reader.Read(); !errors.Is(err, io.EOF) {
		t.Fatalf("got %v, want the daemon to close the connection", err)
	}
}

func TestConcurrentRequests(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	const n = 50
	for i := range n {
		c.send(map[string]any{"jsonrpc": "2.0", "id": 100 + i, "method": "daemon/status"})
	}
	seen := map[string]bool{}
	for range n {
		m := c.read()
		wantOK(t, m)
		seen[string(m.ID)] = true
	}
	if len(seen) != n {
		t.Fatalf("got %d distinct replies, want %d", len(seen), n)
	}
}

func TestMultibyteRoundTrip(t *testing.T) {
	d := startDaemon(t, 0, "cpd-ü🌍-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	var s protocol.StatusResult
	json.Unmarshal(c.request("daemon/status", nil).Result, &s)
	if s.SocketPath != d.opts.SocketPath || !strings.Contains(s.SocketPath, "ü🌍") {
		t.Fatalf("socketPath %q, want %q", s.SocketPath, d.opts.SocketPath)
	}
}

func TestPermissions(t *testing.T) {
	skipOverTCP(t)
	path := filepath.Join(privateDir(t, "cpd-"), "nested", "d.sock")
	d := New(Options{SocketPath: path})
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	defer d.Stop("test")
	dirInfo, _ := os.Stat(filepath.Dir(path))
	sockInfo, _ := os.Stat(path)
	if dirInfo.Mode().Perm() != 0o700 || sockInfo.Mode().Perm() != 0o600 {
		t.Fatalf("dir %o, socket %o; want 700 and 600", dirInfo.Mode().Perm(), sockInfo.Mode().Perm())
	}
}

func TestUnsafeDirIsRefusedNotChmodded(t *testing.T) {
	skipOverTCP(t)
	dir := privateDir(t, "cpd-")
	os.Chmod(dir, 0o755)
	err := New(Options{SocketPath: filepath.Join(dir, "d.sock")}).Start()
	var unsafe *UnsafeDirError
	if !errors.As(err, &unsafe) || !strings.Contains(err.Error(), "other users can reach the socket") {
		t.Fatalf("got %v, want UnsafeDirError", err)
	}
	if info, _ := os.Stat(dir); info.Mode().Perm() != 0o755 {
		t.Fatalf("mode changed to %o", info.Mode().Perm())
	}
}

func TestSecondDaemonIsRefused(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	err := New(Options{SocketPath: d.opts.SocketPath, TCP: overTCP}).Start()
	var already *AlreadyRunningError
	if !errors.As(err, &already) {
		t.Fatalf("got %v, want AlreadyRunningError", err)
	}
	wantOK(t, connect(t, d.opts.SocketPath).initialize(protocol.Version))
}

func TestStaleSocketIsReplaced(t *testing.T) {
	skipOverTCP(t)
	path := filepath.Join(privateDir(t, "cpd-"), "d.sock")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	ln.SetUnlinkOnClose(false)
	ln.Close()
	if !exists(path) {
		t.Fatal("expected a stale socket file")
	}
	d := New(Options{SocketPath: path})
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	defer d.Stop("test")
	wantOK(t, connect(t, path).initialize(protocol.Version))
}

func TestRegularFileIsLeftAlone(t *testing.T) {
	path := filepath.Join(privateDir(t, "cpd-"), "d.sock")
	os.WriteFile(path, []byte("keep me"), 0o600)
	if err := New(Options{SocketPath: path}).Start(); err == nil || !strings.Contains(err.Error(), "not a socket") {
		t.Fatalf("got %v, want a 'not a socket' error", err)
	}
	if data, _ := os.ReadFile(path); string(data) != "keep me" {
		t.Fatal("the file was changed")
	}
}

func TestStopLeavesAnotherDaemonsSocket(t *testing.T) {
	skipOverTCP(t)
	first := startDaemon(t, 0, "cpd-")
	path := first.opts.SocketPath
	os.Remove(path) // someone deletes the socket; a second daemon takes the path
	second := New(Options{SocketPath: path})
	if err := second.Start(); err != nil {
		t.Fatal(err)
	}
	defer second.Stop("test")
	first.Stop("test")
	if !exists(path) {
		t.Fatal("stopping the first daemon removed the second daemon's socket")
	}
	wantOK(t, connect(t, path).initialize(protocol.Version))
}

func TestIdleTimeout(t *testing.T) {
	d := startDaemon(t, 150*time.Millisecond, "cpd-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	time.Sleep(300 * time.Millisecond)
	select {
	case <-d.Done():
		t.Fatal("a connected client must keep the daemon alive")
	default:
	}
	c.nc.Close()
	select {
	case <-d.Done():
	case <-time.After(3 * time.Second):
		t.Fatal("the daemon did not stop after the idle timeout")
	}
	if d.StopReason() != "idle" || exists(d.opts.SocketPath) {
		t.Fatalf("reason %q, socket exists %v", d.StopReason(), exists(d.opts.SocketPath))
	}
}

func TestShutdown(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	wantOK(t, c.initialize(protocol.Version))
	m := c.request("shutdown", map[string]string{"token": c.token})
	wantOK(t, m)
	if string(m.Result) != `{"ok":true}` {
		t.Fatalf("result %s", m.Result)
	}
	c.nc.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.reader.Read(); !errors.Is(err, io.EOF) {
		t.Fatalf("got %v, want the connection closed", err)
	}
	waitFor(t, "the socket to be removed", func() bool { return !exists(d.opts.SocketPath) })
	if d.StopReason() != "shutdown request" {
		t.Fatalf("reason %q", d.StopReason())
	}
}

func TestTheHelperIsThisDaemonsOwnBinary(t *testing.T) {
	path := defaultHelperPath()
	if runtime.GOOS == "linux" {
		if path != fmt.Sprintf("/proc/%d/exe", os.Getpid()) {
			t.Fatalf("helper path %q", path)
		}
		target, err := os.Readlink(path)
		exe, _ := os.Executable()
		if err != nil || target != exe {
			t.Fatalf("%s points at %q (%v), want %q", path, target, err, exe)
		}
		return
	}
	if exe, _ := os.Executable(); path != exe {
		t.Fatalf("helper path %q, want %q", path, exe)
	}
}

func TestShutdownWorksBeforeInitialize(t *testing.T) {
	d := startDaemon(t, 0, "cpd-")
	c := connect(t, d.opts.SocketPath)
	m := c.request("shutdown", map[string]string{"token": c.token})
	wantOK(t, m)
	waitFor(t, "the daemon to stop", func() bool { return !exists(d.opts.SocketPath) })
}

func TestATCPDaemonWantsItsToken(t *testing.T) {
	d := New(Options{SocketPath: filepath.Join(privateDir(t, "cpd-"), "d.json"), TCP: true, Version: "9.9.9-test"})
	if err := d.Start(); err != nil {
		t.Fatal(err)
	}
	defer d.Stop("test")
	info, err := endpoint.Read(d.opts.SocketPath)
	if err != nil || info.PID != os.Getpid() {
		t.Fatalf("endpoint %+v %v", info, err)
	}
	c := connect(t, d.opts.SocketPath)
	good := c.token
	c.token = "wrong"
	wantCode(t, c.initialize(protocol.Version), protocol.Unauthorized)
	wantCode(t, c.request("daemon/status", nil), protocol.NotInitialized)
	wantCode(t, c.request("shutdown", nil), protocol.Unauthorized)
	c.token = good
	wantOK(t, c.initialize(protocol.Version))
	// Once initialized, the connection has shown its token.
	wantOK(t, c.request("shutdown", nil))
	d.Stop("test")
	if _, err := os.Stat(d.opts.SocketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("endpoint file left behind: %v", err)
	}
}
