// Command claude-paird is the daemon that connects the claude-pair Emacs
// package to Claude.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/victory/claude-pair/daemon/internal/paths"
	"github.com/victory/claude-pair/daemon/internal/protocol"
	"github.com/victory/claude-pair/daemon/internal/server"
	"github.com/victory/claude-pair/daemon/internal/version"
)

const exitAlreadyRunning = 3

const usage = `Usage: claude-paird [options]

Daemon that connects the claude-pair Emacs package to Claude.

Options:
  --socket PATH          Socket to listen on (default: %s)
  --idle-timeout SEC     Exit after SEC seconds with no clients; 0 never exits (default: 600)
  --log-file PATH        Append the log to PATH instead of standard error
  --log-level LEVEL      debug, info, warn or error (default: info)
  --detach               Start in the background and return once the socket is ready
  --ready-timeout SEC    With --detach, how long to wait for the socket (default: 10)
  --version              Print the version and exit
  --help                 Print this help and exit
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("claude-paird", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprintf(stderr, usage, paths.DefaultSocketPath()) }
	socket := flags.String("socket", "", "")
	idle := flags.String("idle-timeout", "600", "")
	logFile := flags.String("log-file", "", "")
	logLevel := flags.String("log-level", "info", "")
	detach := flags.Bool("detach", false, "")
	ready := flags.String("ready-timeout", "10", "")
	showVersion := flags.Bool("version", false, "")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if flags.NArg() > 0 {
		fmt.Fprintf(stderr, "claude-paird: unexpected argument %q\n", flags.Arg(0))
		return 2
	}
	if *showVersion {
		fmt.Fprintf(stdout, "claude-paird %s (protocol %s)\n", version.Version, protocol.Version)
		return 0
	}

	idleTimeout, err := seconds(*idle, "--idle-timeout")
	if err != nil {
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		return 2
	}
	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		fmt.Fprintf(stderr, "claude-paird: --log-level must be debug, info, warn or error, got %q\n", *logLevel)
		return 2
	}
	path := *socket
	if path == "" {
		path = paths.DefaultSocketPath()
	}
	if path, err = filepath.Abs(path); err != nil {
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		return 2
	}

	if *detach {
		readyTimeout, err := seconds(*ready, "--ready-timeout")
		if err != nil {
			fmt.Fprintf(stderr, "claude-paird: %v\n", err)
			return 2
		}
		child := []string{"--socket", path, "--idle-timeout", *idle, "--log-level", *logLevel}
		return runDetached(child, path, *logFile, readyTimeout, stdout, stderr)
	}
	return runForeground(path, idleTimeout, *logFile, level, stderr)
}

func seconds(value, flagName string) (time.Duration, error) {
	n, err := strconv.ParseFloat(value, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s needs a number of seconds, got %q", flagName, value)
	}
	return time.Duration(n * float64(time.Second)), nil
}

func runForeground(path string, idleTimeout time.Duration, logFile string, level slog.Level, stderr io.Writer) int {
	out := stderr
	if logFile != "" {
		if err := server.PrepareSocketDir(filepath.Dir(path)); err != nil {
			fmt.Fprintf(stderr, "claude-paird: %v\n", err)
			return 1
		}
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			fmt.Fprintf(stderr, "claude-paird: %v\n", err)
			return 1
		}
		defer f.Close()
		out = f
	}
	log := slog.New(slog.NewTextHandler(out, &slog.HandlerOptions{Level: level}))
	d := server.New(server.Options{SocketPath: path, IdleTimeout: idleTimeout, Version: version.Version, Log: log})
	if err := d.Start(); err != nil {
		log.Error("cannot start", "error", err)
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		var already *server.AlreadyRunningError
		if errors.As(err, &already) {
			return exitAlreadyRunning
		}
		return 1
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	select {
	case s := <-signals:
		d.Stop(s.String())
	case <-d.Done():
	}
	return 0
}

// runDetached starts the daemon in its own session and waits until its socket
// accepts connections. It prints "ready PID SOCKET" or "already running SOCKET".
func runDetached(childArgs []string, path, logFile string, readyTimeout time.Duration, stdout, stderr io.Writer) int {
	// Check here: once detached, the daemon has nowhere to report errors but its log.
	if err := server.PrepareSocketDir(filepath.Dir(path)); err != nil {
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		return 1
	}
	if server.CanConnect(path, 300*time.Millisecond) {
		fmt.Fprintf(stdout, "already running %s\n", path)
		return 0
	}
	if logFile == "" {
		logFile = filepath.Join(filepath.Dir(path), "daemon.log")
	}
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		return 1
	}
	cmd := exec.Command(exe, append(childArgs, "--log-file", logFile)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(stderr, "claude-paird: %v\n", err)
		return 1
	}
	exited := make(chan int, 1)
	go func() {
		err := cmd.Wait()
		var exitErr *exec.ExitError
		switch {
		case errors.As(err, &exitErr):
			exited <- exitErr.ExitCode()
		case err != nil:
			exited <- 1
		default:
			exited <- 0
		}
	}()

	deadline := time.Now().Add(readyTimeout)
	for time.Now().Before(deadline) {
		select {
		case code := <-exited:
			if code == exitAlreadyRunning {
				fmt.Fprintf(stdout, "already running %s\n", path)
				return 0
			}
			fmt.Fprintf(stderr, "claude-paird exited with code %d while starting.\n%s", code, tail(logFile, 5))
			return 1
		default:
		}
		if server.CanConnect(path, 200*time.Millisecond) {
			fmt.Fprintf(stdout, "ready %d %s\n", cmd.Process.Pid, path)
			return 0
		}
		time.Sleep(50 * time.Millisecond)
	}
	fmt.Fprintf(stderr, "claude-paird did not open %s within %s.\n%s", path, readyTimeout, tail(logFile, 5))
	return 1
}

func tail(file string, lines int) string {
	data, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	all := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	text := strings.Join(all, "\n")
	if text == "" {
		return ""
	}
	return fmt.Sprintf("Last lines of %s:\n%s\n", file, text)
}
