//go:build windows

package server

import "io/fs"

// checkPrivate accepts the directory: on Windows the default one is under
// the user's own %LOCALAPPDATA%, whose access list keeps other users out,
// and the endpoint file's token guards the port.
func checkPrivate(string, fs.FileInfo) error { return nil }

// inodeNumber has no meaning on Windows.
func inodeNumber(fs.FileInfo) uint64 { return 0 }
