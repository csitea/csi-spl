package keyexec

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"
)

// SockEnv names the desk's local key socket (spec 127 5.2 step 1). The
// server half is 127 X1's: it checks the caller with SO_PEERCRED, holds the
// lease and opens the hub's sealed answer. This file is the client half and
// the wire both halves speak: one JSON object per line each way.
const SockEnv = "SPOOL_KEY_SOCK"

// Request is one ask to the desk.
//
//	{"op":"lease","kind":"grok","seat":"<dir>"}      the seat start: the held lease, else a new one
//	{"op":"exhausted","kind":"grok","seat":"<dir>"}  the vendor refused it (spec 159 9.1)
//	{"op":"helper","kind":"claude"}                  claude's apiKeyHelper: the held lease only,
//	                                                 never a new hub lease (refused: no_lease)
//
// Seat is the seat's $SPOOL_SEAT_DIR: the desk records it against the
// caller's SO_PEERCRED pid and removes the dir once that pid is gone
// (127 5.4); a path outside its <runtime>/spool-seat/ is refused bad_seat.
type Request struct {
	Op   string `json:"op"`
	Kind string `json:"kind"`
	Seat string `json:"seat,omitempty"`
}

// Reply is the desk's answer. Error is a token, never vendor text:
// key_exhausted, no_key, no_lease, bad_seat, box_not_approved,
// no_metered_key, no_box_key, no_lease_route, bad_kind, bad_request, ...
type Reply struct {
	OK      bool   `json:"ok"`
	Key     string `json:"key,omitempty"`
	BaseURL string `json:"base_url,omitempty"` // qwen only
	Error   string `json:"error,omitempty"`
}

// Lease is a key handed to one seat. String never prints the key.
type Lease struct {
	Key     string
	BaseURL string
}

// String hides the key from every %v and log line.
func (Lease) String() string { return "<VENDOR_KEY>" }

// RefusedError is a lease the desk refused; Token is its error token.
type RefusedError struct{ Token string }

// Error names the refusal token, never vendor text.
func (e *RefusedError) Error() string { return "desk refused the lease: " + e.Token }

// TokenKeyExhausted is the refusal of a key the vendor refused (spec 159 9.2).
const TokenKeyExhausted = "key_exhausted"

// Desk is what the wrapper needs from the desk socket.
type Desk interface {
	Lease(ctx context.Context, kind string) (Lease, error)
	Exhausted(ctx context.Context, kind string) error
}

// SockDesk talks to the desk over its unix socket. Seat, when set, goes
// with every lease and exhausted ask.
type SockDesk struct {
	Path    string
	Seat    string
	Timeout time.Duration
}

// Lease asks for the key of kind at a seat start.
func (d SockDesk) Lease(ctx context.Context, kind string) (Lease, error) {
	return d.lease(ctx, Request{Op: "lease", Kind: kind, Seat: d.Seat})
}

// Helper asks for the key of kind from the lease the desk already holds
// (127 5.2: a helper call never takes a new hub lease).
func (d SockDesk) Helper(ctx context.Context, kind string) (Lease, error) {
	return d.lease(ctx, Request{Op: "helper", Kind: kind})
}

func (d SockDesk) lease(ctx context.Context, req Request) (Lease, error) {
	r, err := d.call(ctx, req)
	if err != nil {
		return Lease{}, err
	}
	if !r.OK {
		return Lease{}, &RefusedError{Token: tokenOr(r.Error)}
	}
	if r.Key == "" {
		return Lease{}, errors.New("desk answered a lease with no key")
	}
	return Lease{Key: r.Key, BaseURL: r.BaseURL}, nil
}

// Exhausted reports that the vendor refused the key of kind.
func (d SockDesk) Exhausted(ctx context.Context, kind string) error {
	r, err := d.call(ctx, Request{Op: "exhausted", Kind: kind, Seat: d.Seat})
	if err != nil {
		return err
	}
	if !r.OK {
		return &RefusedError{Token: tokenOr(r.Error)}
	}
	return nil
}

func tokenOr(t string) string {
	if t == "" {
		return "refused"
	}
	return t
}

func (d SockDesk) call(ctx context.Context, req Request) (Reply, error) {
	if d.Path == "" {
		return Reply{}, fmt.Errorf("no desk key socket: $%s is not set", SockEnv)
	}
	to := d.Timeout
	if to <= 0 {
		to = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, to)
	defer cancel()
	var dl net.Dialer
	c, err := dl.DialContext(ctx, "unix", d.Path)
	if err != nil {
		return Reply{}, fmt.Errorf("desk key socket: %w", err)
	}
	defer c.Close()
	if t, ok := ctx.Deadline(); ok {
		_ = c.SetDeadline(t)
	}
	if err := json.NewEncoder(c).Encode(req); err != nil {
		return Reply{}, fmt.Errorf("desk key socket: write: %w", err)
	}
	line, err := bufio.NewReaderSize(c, 64<<10).ReadBytes('\n')
	if err != nil {
		return Reply{}, fmt.Errorf("desk key socket: read: %w", err)
	}
	var r Reply
	if err := json.Unmarshal(line, &r); err != nil {
		return Reply{}, errors.New("desk key socket: the answer is not one JSON reply")
	}
	return r, nil
}
