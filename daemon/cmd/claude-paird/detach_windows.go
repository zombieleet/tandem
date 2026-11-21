//go:build windows

package main

import "syscall"

// detachedAttr starts the daemon without a console and in a process group
// of its own, so it outlives the Emacs that started it.
func detachedAttr() *syscall.SysProcAttr {
	const detachedProcess, newProcessGroup = 0x00000008, 0x00000200
	return &syscall.SysProcAttr{CreationFlags: detachedProcess | newProcessGroup, HideWindow: true}
}
