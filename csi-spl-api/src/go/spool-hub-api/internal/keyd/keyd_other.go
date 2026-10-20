//go:build !linux && !darwin

package keyd

import "errors"

// errNoPeerCred: this OS has no peer-uid read here, so keyd accepts no peer
// and does not start.
var errNoPeerCred = errors.New("keyd: no peer uid check on this OS")

func sockPeerUID(int) (uint32, error) { return 0, errNoPeerCred }

func harden() error { return errNoPeerCred }
