//go:build !windows

package main

import "syscall"

// detachedAttr starts the daemon in a session of its own, so it outlives
// the Emacs that started it.
func detachedAttr() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setsid: true} }
