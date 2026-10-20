//go:build darwin

package keyd

import (
	"errors"

	"golang.org/x/sys/unix"
)

// sockPeerUID reads the peer's uid with LOCAL_PEERCRED, the macOS
// counterpart of SO_PEERCRED.
func sockPeerUID(fd int) (uint32, error) {
	cred, err := unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		return 0, err
	}
	return cred.Uid, nil
}

// harden has no PR_SET_DUMPABLE on macOS: PT_DENY_ATTACH stops a debugger
// attaching, and a zero RLIMIT_CORE stops core dumps.
func harden() error {
	if err := unix.PtraceDenyAttach(); err != nil {
		return errors.New("could not deny debugger attach")
	}
	var lim unix.Rlimit
	if err := unix.Setrlimit(unix.RLIMIT_CORE, &lim); err != nil {
		return errors.New("could not disable core dumps")
	}
	return nil
}
