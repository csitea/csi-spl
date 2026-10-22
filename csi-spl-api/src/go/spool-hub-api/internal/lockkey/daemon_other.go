//go:build !linux

package lockkey

import (
	"errors"
	"net"
)

// errNoPeerCred: no peer-uid read on this OS, so lockd does not start.
var errNoPeerCred = errors.New("lockd: no peer uid check on this OS")

func peerUID(net.Conn) (uint32, error) { return 0, errNoPeerCred }

func harden() error { return errNoPeerCred }
