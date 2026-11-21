package session

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"
)

// Command is a slash command Claude Code offers.
type Command struct {
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	ArgumentHint string   `json:"argumentHint,omitempty"`
	Aliases      []string `json:"aliases,omitempty"`
	Builtin      bool     `json:"builtin,omitempty"`
}

// terminalOnly are commands Claude Code lists but only runs in its own
// terminal interface.
var terminalOnly = map[string]bool{"doctor": true, "color": true, "focus": true, "reload-plugins": true}

// Commands asks Claude Code which slash commands it offers in this
// session's project: its own, the project's and the user's, skills and
// plugins. It starts a short-lived claude that answers an initialize
// request and never calls a model.
func (s *Session) Commands(ctx context.Context) ([]Command, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.opts.ClaudePath,
		"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose")
	cmd.Dir = s.opts.Cwd
	if len(s.opts.Env) > 0 {
		cmd.Env = MergeEnv(os.Environ(), s.opts.Env)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	if _, err := fmt.Fprintln(stdin, `{"type":"control_request","request_id":"commands","request":{"subtype":"initialize"}}`); err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64<<10), maxLine)
	for scanner.Scan() {
		var msg struct {
			Type     string `json:"type"`
			Response struct {
				Subtype   string `json:"subtype"`
				RequestID string `json:"request_id"`
				Error     string `json:"error"`
				Response  struct {
					Commands []Command `json:"commands"`
				} `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(scanner.Bytes(), &msg) != nil || msg.Type != "control_response" ||
			msg.Response.RequestID != "commands" {
			continue
		}
		if msg.Response.Subtype == "error" {
			return nil, fmt.Errorf("claude: %s", msg.Response.Error)
		}
		commands := []Command{}
		for _, c := range msg.Response.Response.Commands {
			if c.Name != "" && !terminalOnly[c.Name] {
				commands = append(commands, c)
			}
		}
		return commands, nil
	}
	if ctx.Err() != nil {
		return nil, errors.New("claude did not list its commands within 30 s")
	}
	return nil, errors.New("claude ended without listing its commands")
}
