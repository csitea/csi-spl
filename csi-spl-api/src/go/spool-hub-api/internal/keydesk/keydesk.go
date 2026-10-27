// Package keydesk is the desk's half of a workspace's vendor keys (spec 127
// X1, 5.2 and 5.4; spec 159 T3 remainder): the local key socket a seat's
// `spool key-exec` and claude's `spool key-helper` ask (their half is
// internal/keyexec), the lease the desk holds in memory, the hub's sealed
// answer opened with the desk's X25519 identity, the seat-dir sweep and the
// redaction of every key it handed out from the box's outbound text.
//
// The wire (agreed with the client lane, spec 159 9.1): one unix stream
// connection per ask, one JSON object per line each way.
//
//	{"op":"lease","kind":"grok","seat":"<seat dir>"}  a seat starts: the held lease, else a hub lease
//	{"op":"helper","kind":"claude"}                   claude's apiKeyHelper: the held lease only
//	{"op":"exhausted","kind":"grok","seat":"..."}     the vendor refused the key (spec 159 9.1)
//	{"op":"redact","text":"..."}                      the text with every handed-out key removed
//
// A reply is {"ok":true,...} or {"ok":false,"error":"<token>"}; a token is
// never vendor text. A peer that is not the desk's own uid gets nothing at
// all: the connection is closed before a byte is read or written.
package keydesk

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"filippo.io/age"
)

// Error tokens of the desk socket (spec 159 9.1 plus X1's own).
const (
	TokNoLease      = "no_lease"       // helper: the desk holds no lease of that kind
	TokBadSeat      = "bad_seat"       // the seat path is not a seat dir of this desk
	TokNoBoxKey     = "no_box_key"     // the desk holds no X25519 identity to open a lease
	TokNoLeaseRoute = "no_lease_route" // the hub's lease route answered 404 (127 H2 not live)
	TokHubDown      = "hub_unreachable"
	TokBadSeal      = "bad_seal" // the sealed answer did not open, or names another kind or box
	TokBadKind      = "bad_kind"
	TokBadRequest   = "bad_request"
	TokKeyExhausted = "key_exhausted"
)

// Removed replaces a handed-out key in outbound text (127 L9).
const Removed = "[vendor key removed]"

// SockName is the socket's file name in the box root's hub dir: one path
// that the sidecar, a seat's launcher ($SPOOL_KEY_SOCK) and every `spool
// send` of that root derive alike.
const SockName = "key.sock"

// SockPath is the key socket of the box root whose hub dir is hubDir.
func SockPath(hubDir string) string { return filepath.Join(hubDir, SockName) }

// maxLine caps one ask: a redact text is a spool body, far smaller.
const maxLine = 4 << 20

// kinds are the five key kinds of spec 127 3.
var kinds = map[string]bool{"claude": true, "grok": true, "agy": true, "mistral": true, "qwen": true}

// request is one ask. Unknown fields are ignored, so the client may grow.
type request struct {
	Op   string `json:"op"`
	Kind string `json:"kind,omitempty"`
	Seat string `json:"seat,omitempty"`
	Text string `json:"text,omitempty"`
}

// reply is the desk's answer; its first four fields are keyexec.Reply's.
type reply struct {
	OK      bool    `json:"ok"`
	Key     string  `json:"key,omitempty"`
	BaseURL string  `json:"base_url,omitempty"`
	Error   string  `json:"error,omitempty"`
	Text    *string `json:"text,omitempty"`
}

// Hub is what the desk needs from the hub (127 5.2 step 2, 159 9.1).
type Hub interface {
	// Lease returns the hub's sealed answer for kind (127 5.2 step 3).
	Lease(ctx context.Context, kind string) ([]byte, error)
	// Exhausted reports the vendor's refusal of kind, with no vendor text.
	Exhausted(ctx context.Context, kind string) error
}

// Refused is a hub refusal; Token is its error token (box_not_approved,
// no_key, key_exhausted, ...), passed to the seat as it is.
type Refused struct{ Token string }

// Error names the hub's token, never vendor text.
func (e *Refused) Error() string { return "hub refused: " + e.Token }

// Peer is the caller as SO_PEERCRED reports it.
type Peer struct {
	PID      int32
	UID, GID uint32
}

// held is one lease in the desk's memory. String never prints the key.
type held struct {
	key, baseURL string
	until        time.Time
}

func (held) String() string { return "<VENDOR_KEY>" }

// Server is the desk key socket.
type Server struct {
	Path     string        // the socket, SockPath(<hub dir>)
	SeatRoot string        // <runtime>/spool-seat (127 5.4)
	Box      string        // this desk's box id: a sealed lease must name it
	Hub      Hub           // nil: every hub lease is refused no_lease_route
	Identity age.Identity  // nil: no_box_key
	TTL      time.Duration // lease TTL, default 15 min (127 5.2)
	Grace    time.Duration // an unclaimed seat dir lives this long, default 10 min
	// PeerOK admits a caller; nil = DefaultPeerOK (own uid, no root-equivalent group).
	PeerOK func(Peer) error
	Log    func(string) // one line per refusal and sweep; never a key
	Now    func() time.Time

	once      sync.Once
	mu        sync.Mutex
	leases    map[string]held
	exhausted map[string]time.Time
	handed    map[string]struct{} // every key handed out while the desk lives (L9)
	seats     map[string]seatRec
	ln        net.Listener
}

func (s *Server) init() {
	s.once.Do(func() {
		s.leases = map[string]held{}
		s.exhausted = map[string]time.Time{}
		s.handed = map[string]struct{}{}
		s.seats = map[string]seatRec{}
	})
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) ttl() time.Duration {
	if s.TTL > 0 {
		return s.TTL
	}
	return 15 * time.Minute
}

func (s *Server) logf(format string, a ...any) {
	if s.Log != nil {
		s.Log(fmt.Sprintf(format, a...))
	}
}

// Listen opens the socket, 0600 in its 0700 dir. A live socket on the path
// is another desk's: refused, never stolen.
func (s *Server) Listen() error {
	s.init()
	if s.Path == "" {
		return errors.New("keydesk: no socket path")
	}
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	if c, err := net.DialTimeout("unix", s.Path, time.Second); err == nil {
		c.Close() //nolint:errcheck
		return fmt.Errorf("keydesk: another desk is listening on %s", s.Path)
	}
	os.Remove(s.Path) //nolint:errcheck
	ln, err := net.Listen("unix", s.Path)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.Path, 0o600); err != nil {
		ln.Close() //nolint:errcheck
		return err
	}
	s.ln = ln
	return nil
}

// Serve answers asks until ctx ends, then removes the socket.
func (s *Server) Serve(ctx context.Context) {
	go func() {
		<-ctx.Done()
		s.ln.Close()      //nolint:errcheck
		os.Remove(s.Path) //nolint:errcheck
	}()
	for {
		c, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.handle(ctx, c)
	}
}

// handle serves one connection: the peer check first, before any read.
func (s *Server) handle(ctx context.Context, c net.Conn) {
	defer c.Close() //nolint:errcheck
	p, err := peerOf(c)
	if err == nil {
		err = s.peerOK(p)
	}
	if err != nil {
		s.logf("keydesk: refused a peer: %v", err) // nothing is written back
		return
	}
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	r := reply{Error: TokBadRequest}
	line, err := bufio.NewReader(io.LimitReader(c, maxLine)).ReadBytes('\n')
	var req request
	if err == nil && json.Unmarshal(line, &req) == nil {
		r = s.answer(ctx, p, req)
	}
	out, _ := json.Marshal(r)
	_, _ = c.Write(append(out, '\n'))
}

func (s *Server) peerOK(p Peer) error {
	if s.PeerOK != nil {
		return s.PeerOK(p)
	}
	return DefaultPeerOK(p)
}

// answer runs one op.
func (s *Server) answer(ctx context.Context, p Peer, req request) reply {
	if req.Op == "redact" {
		t := s.Redact(req.Text)
		return reply{OK: true, Text: &t}
	}
	if !kinds[req.Kind] {
		return reply{Error: TokBadKind}
	}
	switch req.Op {
	case "lease":
		if tok := s.claimSeat(req.Seat, req.Kind, p); tok != "" {
			return reply{Error: tok}
		}
		return s.lease(ctx, req.Kind)
	case "helper":
		return s.helper(req.Kind)
	case "exhausted":
		return s.markExhausted(ctx, req.Kind)
	}
	return reply{Error: TokBadRequest}
}

// helper answers claude's apiKeyHelper from the held lease only (127 5.2
// step 5: never a new hub lease per helper call).
func (s *Server) helper(kind string) reply {
	s.mu.Lock()
	defer s.mu.Unlock()
	h, ok := s.leases[kind]
	if !ok || !s.now().Before(h.until) {
		return reply{Error: TokNoLease}
	}
	return reply{OK: true, Key: h.key, BaseURL: h.baseURL}
}

// lease answers a seat start: the held lease, else a new one from the hub.
func (s *Server) lease(ctx context.Context, kind string) reply {
	s.mu.Lock()
	if t, ok := s.exhausted[kind]; ok && s.now().Before(t) {
		s.mu.Unlock()
		return reply{Error: TokKeyExhausted}
	}
	if h, ok := s.leases[kind]; ok && s.now().Before(h.until) {
		s.mu.Unlock()
		return reply{OK: true, Key: h.key, BaseURL: h.baseURL}
	}
	s.mu.Unlock()
	h, tok := s.fetch(ctx, kind)
	if tok != "" {
		return reply{Error: tok}
	}
	s.mu.Lock()
	s.leases[kind] = h
	s.handed[h.key] = struct{}{}
	s.mu.Unlock()
	return reply{OK: true, Key: h.key, BaseURL: h.baseURL}
}

// fetch takes a lease from the hub and opens it; it returns a token on
// refusal. The hub's own error token passes through as it is.
func (s *Server) fetch(ctx context.Context, kind string) (held, string) {
	if s.Identity == nil {
		return held{}, TokNoBoxKey
	}
	if s.Hub == nil {
		return held{}, TokNoLeaseRoute
	}
	sealed, err := s.Hub.Lease(ctx, kind)
	var re *Refused
	switch {
	case errors.As(err, &re):
		s.logf("keydesk: hub refused the %s lease: %s", kind, re.Token)
		return held{}, re.Token
	case err != nil:
		s.logf("keydesk: %s lease: hub unreachable", kind)
		return held{}, TokHubDown
	}
	p, err := Open(s.Identity, sealed)
	if err != nil || p.Kind != kind || (s.Box != "" && p.Box != s.Box) || p.Key == "" {
		s.logf("keydesk: the %s lease did not open for this box", kind)
		return held{}, TokBadSeal
	}
	ttl := s.ttl()
	if d := time.Duration(p.TTLSeconds) * time.Second; d > 0 && d < ttl {
		ttl = d
	}
	return held{key: p.Key, baseURL: p.BaseURL, until: s.now().Add(ttl)}, ""
}

// markExhausted drops the held lease of kind and refuses new ones for one
// TTL (the hub's 409 key_exhausted takes over once it is live), then tells
// the hub. The hub report is best effort: the seat has stopped either way.
func (s *Server) markExhausted(ctx context.Context, kind string) reply {
	s.mu.Lock()
	delete(s.leases, kind)
	s.exhausted[kind] = s.now().Add(s.ttl())
	s.mu.Unlock()
	if s.Hub != nil {
		if err := s.Hub.Exhausted(ctx, kind); err != nil {
			s.logf("keydesk: the %s exhausted report did not reach the hub", kind)
		}
	}
	return reply{OK: true}
}

// Redact replaces every key this desk handed out with Removed (127 L9, the
// desk half): the exact key, wherever it stands in the text.
func (s *Server) Redact(text string) string {
	s.init()
	s.mu.Lock()
	defer s.mu.Unlock()
	for k := range s.handed {
		if len(k) >= 8 {
			text = strings.ReplaceAll(text, k, Removed)
		}
	}
	return text
}

// Expire drops every lease past its TTL (the key stays in the redaction set).
func (s *Server) Expire() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, h := range s.leases {
		if !s.now().Before(h.until) {
			delete(s.leases, k)
		}
	}
}

// Run empties the seat root, listens and serves, and on every tick expires
// leases and sweeps seat dirs, until ctx ends.
func (s *Server) Run(ctx context.Context, tick time.Duration) error {
	s.init()
	if err := s.EmptySeats(); err != nil {
		return err
	}
	if err := s.Listen(); err != nil {
		return err
	}
	go s.Serve(ctx)
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			s.Expire()
			s.Sweep()
		}
	}
}
