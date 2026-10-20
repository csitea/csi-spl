//go:build linux

package keyd

import (
	"errors"

	"golang.org/x/sys/unix"
)

// sockPeerUID reads the peer's uid with SO_PEERCRED.
func sockPeerUID(fd int) (uint32, error) {
	cred, err := unix.GetsockoptUcred(fd, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		return 0, err
	}
	return cred.Uid, nil
}

func harden() error {
	if err := unix.Prctl(unix.PR_SET_DUMPABLE, 0, 0, 0, 0); err != nil {
		return errors.New("could not disable dumps")
	}
	var lim unix.Rlimit
	if err := unix.Setrlimit(unix.RLIMIT_CORE, &lim); err != nil {
		return errors.New("could not disable core dumps")
	}
	return nil
}
