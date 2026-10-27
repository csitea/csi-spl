//go:build linux

package keydesk

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

// peerOf reads the caller with SO_PEERCRED (127 5.2 step 1): the kernel's
// word, not the socket file's mode.
func peerOf(c net.Conn) (Peer, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return Peer{}, errors.New("not a unix connection")
	}
	rc, err := uc.SyscallConn()
	if err != nil {
		return Peer{}, err
	}
	var cred *unix.Ucred
	var cerr error
	if err := rc.Control(func(fd uintptr) {
		cred, cerr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return Peer{}, err
	}
	if cerr != nil {
		return Peer{}, cerr
	}
	return Peer{PID: cred.Pid, UID: cred.Uid, GID: cred.Gid}, nil
}

// DefaultPeerOK admits only the desk's own uid (127 5.2 step 1), and only a
// process in no root-equivalent group (127 5.3, s-claude-2 C5): such a
// process reads every seat anyway, and on a workspace desk none should exist.
func DefaultPeerOK(p Peer) error {
	if err := OwnUID(p); err != nil {
		return err
	}
	gids, err := procGroups(p.PID)
	if err != nil {
		return fmt.Errorf("pid %d: groups unreadable: %w", p.PID, err)
	}
	group, err := os.ReadFile("/etc/group")
	if err != nil {
		return fmt.Errorf("/etc/group unreadable: %w", err)
	}
	if g := RootEquivalentIn(string(group), append(gids, p.GID)); g != "" {
		return fmt.Errorf("pid %d is in the root-equivalent group %s", p.PID, g)
	}
	return nil
}

// deskUIDOver, when not 0, is uid+1 of the desk: a test plays another user.
var deskUIDOver atomic.Int64

// deskUID is the desk's own uid.
func deskUID() int {
	if v := deskUIDOver.Load(); v != 0 {
		return int(v - 1)
	}
	return os.Geteuid()
}

// OwnUID admits only the desk's own uid.
func OwnUID(p Peer) error {
	if int(p.UID) != deskUID() {
		return fmt.Errorf("uid %d is not the desk's uid %d", p.UID, deskUID())
	}
	return nil
}

// procGroups is the Groups: line of /proc/<pid>/status.
func procGroups(pid int32) ([]uint32, error) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(int(pid)) + "/status")
	if err != nil {
		return nil, err
	}
	return ParseStatusGroups(string(b))
}

// ParseStatusGroups reads the Groups: line of a /proc/<pid>/status text.
func ParseStatusGroups(status string) ([]uint32, error) {
	for _, l := range strings.Split(status, "\n") {
		rest, ok := strings.CutPrefix(l, "Groups:")
		if !ok {
			continue
		}
		var out []uint32
		for _, f := range strings.Fields(rest) {
			n, err := strconv.ParseUint(f, 10, 32)
			if err != nil {
				return nil, fmt.Errorf("bad gid %q", f)
			}
			out = append(out, uint32(n))
		}
		return out, nil
	}
	return nil, errors.New("no Groups: line")
}
