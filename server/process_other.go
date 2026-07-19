//go:build !windows

package main

import "os/exec"

func hideChildProcessWindow(_ *exec.Cmd) {}
