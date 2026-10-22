//go:build linux

package lockkey

import (
	"errors"
	"net"

	"golang.org/x/sys/unix"
)

// peerUID reads the peer's uid with SO_PEERCRED.
func peerUID(conn net.Conn) (uint32, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, errors.New("not a unix connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var cerr error
	if err := raw.Control(func(fd uintptr) {
		cred, e := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if e != nil {
			cerr = e
			return
		}
		uid = cred.Uid
	}); err != nil {
		return 0, err
	}
	return uid, cerr
}

// harden keeps the unlocked keys out of core dumps and ptrace by other users.
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
