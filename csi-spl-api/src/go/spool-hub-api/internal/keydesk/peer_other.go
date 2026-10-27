//go:build !linux

package keydesk

import (
	"errors"
	"net"
)

// peerOf: SO_PEERCRED is Linux's; elsewhere the desk admits no one.
func peerOf(net.Conn) (Peer, error) {
	return Peer{}, errors.New("keydesk: the desk key socket needs SO_PEERCRED (linux)")
}

// DefaultPeerOK refuses every caller off Linux.
func DefaultPeerOK(Peer) error { return errors.New("keydesk: linux only") }

// OwnUID refuses every caller off Linux.
func OwnUID(Peer) error { return errors.New("keydesk: linux only") }
