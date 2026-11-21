//go:build !windows

package server

import (
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

// checkPrivate refuses a directory that is not the user's own and private.
func checkPrivate(dir string, info fs.FileInfo) error {
	if st, ok := info.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return &UnsafeDirError{fmt.Sprintf("%s belongs to uid %d, not to you (uid %d)", dir, st.Uid, os.Getuid())}
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return &UnsafeDirError{fmt.Sprintf(
			"%s has mode %o, so other users can reach the socket; run chmod 700 on it or pick another directory", dir, perm)}
	}
	return nil
}

// inodeNumber returns the inode of info's file, or 0.
func inodeNumber(info fs.FileInfo) uint64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Ino)
	}
	return 0
}
