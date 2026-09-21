package hubclient

// specs/030 FP-2: a box reply goes out over the sidecar's ALREADY-WARM hub
// session instead of dialling a new one.
//
// Why (measured 2026-09-21 against the live dev hub, version 0.1.17, n=20):
// SendMessage -> sendNow -> Dial(role=cli) opens a brand-new WebSocket per
// outbound message - TCP, TLS, HTTP upgrade, challenge, hello, welcome, one
// frame, close - costing 220.6 ms p50 / 266.5 ms p95 before the hello starts,
// while `spool hub-run` holds an authenticated socket to that same hub. One
// round trip on the warm socket is 61.5 ms p50.
//
// Shape: one JSON line in, one JSON line out, over a unix socket in HubDir.
// Nothing about the ENVELOPE changes - the sidecar writes the exact bytes the
// CLI signed, so the hub cannot tell the two paths apart and every signature is
// byte-identical (spec FR-006). This is box-local plumbing, not a wire change.
//
// Durability is unchanged: the CLI still writes the outbox and the pending
// envelope BEFORE it submits (flush.go), so a sidecar that dies mid-submit
// loses nothing - the pending file is flushed later, and the hub dedups on
// msg_id. The fallback when no sidecar is listening is exactly the pre-030
// dial, which is also the rollback (SPOOL_SUBMIT_SOCKET=off).

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// submitDialTimeout bounds the connect to a LOCAL socket. It is short on
// purpose: a sidecar that is not listening must cost a `spool send` almost
// nothing before it falls back to the 220 ms dial it would have paid anyway.
const submitDialTimeout = 250 * time.Millisecond

// submitReplyTimeout bounds the wait for the sidecar's answer. It is the hub
// round trip plus the sidecar's own queueing, generously: exceeding it means
// the send falls back to pending, never to a duplicate.
const submitReplyTimeout = 30 * time.Second

// submitRequest is one line in: the signed envelope, exactly as the CLI would
// have written it on its own socket.
type submitRequest struct {
	V   int             `json:"v"`
	Env json.RawMessage `json:"env"`
}

// submitResponse is one line out. Delivery is the hub's `sent` frame value on
// success; a refusal carries the hub's own token/status so the CLI can tell a
// permanent 4xx (reject the pending file) from a retryable one.
type submitResponse struct {
	Delivery string `json:"delivery,omitempty"`
	Error    string `json:"error,omitempty"`
	Token    string `json:"token,omitempty"`
	Status   int    `json:"status,omitempty"`
}

// errNoSidecar means no submit listener answered; the caller dials instead.
var errNoSidecar = errors.New("no submit listener")

// submit hands raw to a local sidecar and returns the hub's delivery. It
// returns errNoSidecar when there is nothing to hand it to, which is not a
// failure: it is the pre-030 path.
func (c *Client) submit(ctx context.Context, raw []byte) (string, error) {
	path := c.Cfg.SubmitPath()
	if path == "" {
		return "", errNoSidecar
	}
	d := net.Dialer{Timeout: submitDialTimeout}
	dctx, cancel := context.WithTimeout(ctx, submitDialTimeout)
	defer cancel()
	conn, err := d.DialContext(dctx, "unix", path)
	if err != nil {
		return "", errNoSidecar // stale socket file, no sidecar, wrong perms
	}
	defer conn.Close()

	line, err := json.Marshal(submitRequest{V: 1, Env: raw})
	if err != nil {
		return "", err
	}
	deadline := time.Now().Add(submitReplyTimeout)
	if dl, ok := ctx.Deadline(); ok && dl.Before(deadline) {
		deadline = dl
	}
	conn.SetDeadline(deadline) //nolint:errcheck
	if _, err := conn.Write(append(line, '\n')); err != nil {
		// Half-written: the pending file still holds it, so a later flush
		// sends it and the hub dedups on msg_id. Never a duplicate delivery.
		return "", fmt.Errorf("%w: submit write: %v", ErrUnreachable, err)
	}
	var resp submitResponse
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&resp); err != nil {
		return "", fmt.Errorf("%w: submit reply: %v", ErrUnreachable, err)
	}
	if resp.Token != "" {
		return "", &HubError{Token: resp.Token, Status: resp.Status, Detail: resp.Error}
	}
	if resp.Error != "" {
		return "", fmt.Errorf("%w: sidecar: %s", ErrUnreachable, resp.Error)
	}
	return resp.Delivery, nil
}

// ---- the sidecar side --------------------------------------------------------

// SubmitServer accepts local submissions and writes them on one warm Session.
type SubmitServer struct {
	c  *Client
	ln net.Listener

	// one Session write at a time. hubclient's Session multiplexes replies on
	// ONE channel matched by msg_id, so two concurrent Sends could consume each
	// other's reply. Serialising here keeps the reply that a caller is waiting
	// for the reply it gets. An interactive box sends far below the ~16/s one
	// 61.5 ms round trip allows.
	mu sync.Mutex
}

// Listen opens the submit socket. A stale socket file from a crashed sidecar is
// removed first (a live one would still be accepting, and the caller checks).
// The socket is 0600: only this box's owner may hand it an envelope to sign off.
func (c *Client) Listen() (*SubmitServer, error) {
	path := c.Cfg.SubmitPath()
	if path == "" {
		return nil, nil // submit off by cnf: the sidecar just does not listen
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	// Only remove a socket nobody is serving: if a dial succeeds, another
	// sidecar owns this box root and this one must not steal its callers.
	if conn, err := net.DialTimeout("unix", path, submitDialTimeout); err == nil {
		conn.Close()
		return nil, fmt.Errorf("another sidecar is already listening on %s", path)
	}
	os.Remove(path) //nolint:errcheck
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return &SubmitServer{c: c, ln: ln}, nil
}

// Serve answers submissions on sess until ctx ends or the listener closes.
func (s *SubmitServer) Serve(ctx context.Context, sess *Session) {
	if s == nil {
		return
	}
	go func() {
		<-ctx.Done()
		s.ln.Close() //nolint:errcheck
	}()
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.handle(ctx, sess, conn)
	}
}

// Close stops listening and removes the socket file.
func (s *SubmitServer) Close() {
	if s == nil {
		return
	}
	addr := s.ln.Addr().String()
	s.ln.Close()    //nolint:errcheck
	os.Remove(addr) //nolint:errcheck
}

func (s *SubmitServer) handle(ctx context.Context, sess *Session, conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(submitReplyTimeout)) //nolint:errcheck
	reply := func(r submitResponse) {
		line, err := json.Marshal(r)
		if err != nil {
			return
		}
		conn.Write(append(line, '\n')) //nolint:errcheck
	}
	var req submitRequest
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&req); err != nil {
		reply(submitResponse{Error: "submit request does not parse"})
		return
	}
	env, err := wire.ParseEnvelope(req.Env)
	if err != nil {
		reply(submitResponse{Error: err.Error()})
		return
	}
	s.mu.Lock()
	f, err := sess.Send(ctx, env)
	s.mu.Unlock()
	var he *HubError
	switch {
	case errors.As(err, &he):
		// A hub refusal is the CLI's to act on (a 4xx rejects the pending
		// file); pass the token through rather than flattening it to a string.
		reply(submitResponse{Error: he.Detail, Token: he.Token, Status: he.Status})
	case err != nil:
		reply(submitResponse{Error: err.Error()})
	default:
		reply(submitResponse{Delivery: f.Delivery})
	}
}
