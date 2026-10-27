//go:build linux

package keydesk

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"filippo.io/age"
)

// fakeKey is the obvious fake of spec 127 6; nothing real is ever used.
const fakeKey = "sk-test-0000"

// fakeHub seals a fake key to the desk, or refuses with tok.
type fakeHub struct {
	to        age.Recipient
	p         Payload
	tok       string
	err       error
	leases    atomic.Int32
	exhausted atomic.Int32
}

func (h *fakeHub) Lease(_ context.Context, kind string) ([]byte, error) {
	h.leases.Add(1)
	if h.tok != "" {
		return nil, &Refused{Token: h.tok}
	}
	if h.err != nil {
		return nil, h.err
	}
	p := h.p
	if p.Kind == "" {
		p.Kind = kind
	}
	return Seal(h.to, p)
}

func (h *fakeHub) Exhausted(context.Context, string) error {
	h.exhausted.Add(1)
	return nil
}

// shortDir is a temp dir short enough for a unix socket path (108 bytes).
func shortDir(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("", "kd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

// startDesk runs a desk with a fake hub; PeerOK is the uid check alone, as
// the test user may well sit in a root-equivalent group on a dev box.
func startDesk(t *testing.T, mut func(*Server, *fakeHub)) (*Server, *fakeHub) {
	t.Helper()
	d := shortDir(t)
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	hub := &fakeHub{to: id.Recipient(), p: Payload{Box: "box-1", KeyID: "k1", Key: fakeKey}}
	s := &Server{Path: SockPath(filepath.Join(d, ".hub")), SeatRoot: filepath.Join(d, "spool-seat"),
		Box: "box-1", Hub: hub, Identity: id, PeerOK: OwnUID}
	if mut != nil {
		mut(s, hub)
	}
	if err := s.EmptySeats(); err != nil {
		t.Fatal(err)
	}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go s.Serve(ctx)
	return s, hub
}

// ask sends one request line and returns the raw reply bytes.
func ask(t *testing.T, sock string, req any) []byte {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	// A refused peer may find the socket closed before it writes (EPIPE):
	// that is the refusal itself, read below as zero bytes back.
	_ = json.NewEncoder(c).Encode(req)
	b, _ := io.ReadAll(bufio.NewReader(c))
	return b
}

func askReply(t *testing.T, sock string, req any) reply {
	t.Helper()
	var r reply
	if err := json.Unmarshal(ask(t, sock, req), &r); err != nil {
		t.Fatalf("reply is not JSON: %v", err)
	}
	return r
}

// TestRedControlOtherUIDRefused: a peer with another uid is refused and
// nothing is written back, nor any lease taken (127 5.2 step 1).
// RED CONTROL: OwnUID returning nil -> the peer gets a key.
func TestRedControlOtherUIDRefused(t *testing.T) {
	s, hub := startDesk(t, nil)                       // PeerOK = OwnUID: the uid guard alone
	deskUIDOver.Store(int64(os.Geteuid()) + 4242 + 1) // the desk is another user now
	t.Cleanup(func() { deskUIDOver.Store(0) })
	out := ask(t, s.Path, request{Op: "lease", Kind: "grok"})
	if len(out) != 0 {
		t.Fatalf("a peer of another uid got %d bytes back: %q", len(out), out)
	}
	if n := hub.leases.Load(); n != 0 {
		t.Fatalf("a refused peer caused %d hub leases", n)
	}
}

// TestRedControlHelperNoLease: claude's helper with no lease held is
// refused no_lease and never makes a hub lease; after a seat's lease it is
// answered from the held lease, still with one hub lease in all.
// RED CONTROL: helper falling through to lease() -> a key with no lease held.
func TestRedControlHelperNoLease(t *testing.T) {
	s, hub := startDesk(t, nil)
	if r := askReply(t, s.Path, request{Op: "helper", Kind: "claude"}); r.OK || r.Error != TokNoLease || r.Key != "" {
		t.Fatalf("helper with no lease held: %+v, want refused %s", r, TokNoLease)
	}
	if n := hub.leases.Load(); n != 0 {
		t.Fatalf("helper made %d hub leases, want 0", n)
	}
	if r := askReply(t, s.Path, request{Op: "lease", Kind: "claude"}); !r.OK || r.Key != fakeKey {
		t.Fatalf("seat lease: %+v", r)
	}
	for i := 0; i < 6; i++ { // B0 counted 6 helper calls in 40 s
		if r := askReply(t, s.Path, request{Op: "helper", Kind: "claude"}); !r.OK || r.Key != fakeKey {
			t.Fatalf("helper after a lease: %+v", r)
		}
	}
	if n := hub.leases.Load(); n != 1 {
		t.Fatalf("hub leases = %d, want 1 (helper answers from the held lease)", n)
	}
}

// TestRedControlRedactHandedKey: a key the desk handed out is removed from
// an outbound line, through the socket a `spool send` asks (127 L9).
// RED CONTROL: Redact returning text unchanged -> the fake reaches the line.
func TestRedControlRedactHandedKey(t *testing.T) {
	s, _ := startDesk(t, nil)
	line := "env dump: XAI_API_KEY=" + fakeKey + " and again " + fakeKey + "."
	got, err := RedactVia(context.Background(), s.Path, line)
	if err != nil || got != line {
		t.Fatalf("before any lease: %q, %v; want unchanged", got, err)
	}
	askReply(t, s.Path, request{Op: "lease", Kind: "grok"})
	got, err = RedactVia(context.Background(), s.Path, line)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, fakeKey) || strings.Count(got, Removed) != 2 {
		t.Fatalf("outbound line after a lease: %q", got)
	}
	s.TTL, s.Now = time.Minute, func() time.Time { return time.Now().Add(time.Hour) }
	s.Expire()
	if got := s.Redact(line); strings.Contains(got, fakeKey) {
		t.Fatal("an expired lease's key is no longer redacted")
	}
}

func TestRedactViaNoSocketPassesFailsClosedOnDead(t *testing.T) {
	d := shortDir(t)
	sock := filepath.Join(d, SockName)
	if got, err := RedactVia(context.Background(), sock, "x "+fakeKey); err != nil || got != "x "+fakeKey {
		t.Fatalf("no socket: %q %v", got, err)
	}
	if err := os.WriteFile(sock, nil, 0o600); err != nil { // a stale file, nobody listening
		t.Fatal(err)
	}
	if _, err := RedactVia(context.Background(), sock, "x"); err == nil {
		t.Fatal("a dead key socket let the text through")
	}
}

func TestLeaseRefusals(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*Server, *fakeHub)
		want string
	}{
		{"hub token passes through", func(_ *Server, h *fakeHub) { h.tok = "box_not_approved" }, "box_not_approved"},
		{"hub down", func(_ *Server, h *fakeHub) { h.err = errors.New("dial") }, TokHubDown},
		{"no identity", func(s *Server, _ *fakeHub) { s.Identity = nil }, TokNoBoxKey},
		{"no hub", func(s *Server, _ *fakeHub) { s.Hub = nil }, TokNoLeaseRoute},
		{"sealed for another kind", func(_ *Server, h *fakeHub) { h.p.Kind = "qwen" }, TokBadSeal},
		{"sealed for another box", func(_ *Server, h *fakeHub) { h.p.Box = "box-2" }, TokBadSeal},
		{"sealed to another desk", func(_ *Server, h *fakeHub) {
			other, _ := age.GenerateX25519Identity()
			h.to = other.Recipient()
		}, TokBadSeal},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, _ := startDesk(t, c.mut)
			r := askReply(t, s.Path, request{Op: "lease", Kind: "grok"})
			if r.OK || r.Error != c.want || r.Key != "" {
				t.Fatalf("%+v, want %s", r, c.want)
			}
			if got := s.Redact(fakeKey); got != fakeKey {
				t.Fatal("a refused lease entered the redaction set")
			}
		})
	}
}

func TestBadRequests(t *testing.T) {
	s, hub := startDesk(t, nil)
	for _, req := range []any{
		request{Op: "lease", Kind: "nope"},
		request{Op: "grant", Kind: "grok"},
		"not an object",
	} {
		if r := askReply(t, s.Path, req); r.OK {
			t.Fatalf("%v answered ok", req)
		}
	}
	if hub.leases.Load() != 0 {
		t.Fatal("a bad request reached the hub")
	}
}

func TestExhaustedRefusesForOneTTL(t *testing.T) {
	now := time.Now()
	s, hub := startDesk(t, func(s *Server, _ *fakeHub) {
		s.TTL, s.Now = time.Minute, func() time.Time { return now }
	})
	askReply(t, s.Path, request{Op: "lease", Kind: "grok"})
	if r := askReply(t, s.Path, request{Op: "exhausted", Kind: "grok"}); !r.OK {
		t.Fatalf("exhausted: %+v", r)
	}
	if hub.exhausted.Load() != 1 {
		t.Fatal("the hub was not told")
	}
	if r := askReply(t, s.Path, request{Op: "lease", Kind: "grok"}); r.Error != TokKeyExhausted {
		t.Fatalf("lease after exhausted: %+v", r)
	}
	if r := askReply(t, s.Path, request{Op: "helper", Kind: "grok"}); r.Error != TokNoLease {
		t.Fatalf("helper after exhausted: %+v", r)
	}
	now = now.Add(2 * time.Minute)
	if r := askReply(t, s.Path, request{Op: "lease", Kind: "grok"}); !r.OK {
		t.Fatalf("lease one TTL later: %+v", r)
	}
	if hub.leases.Load() != 2 {
		t.Fatalf("hub leases = %d, want 2", hub.leases.Load())
	}
}

func TestLeaseTTLTakesTheShorter(t *testing.T) {
	now := time.Now()
	s, hub := startDesk(t, func(s *Server, h *fakeHub) {
		s.Now = func() time.Time { return now }
		h.p.TTLSeconds = 30
	})
	askReply(t, s.Path, request{Op: "lease", Kind: "qwen"})
	now = now.Add(31 * time.Second)
	if r := askReply(t, s.Path, request{Op: "helper", Kind: "qwen"}); r.Error != TokNoLease {
		t.Fatalf("helper past the hub's ttl: %+v", r)
	}
	askReply(t, s.Path, request{Op: "lease", Kind: "qwen"})
	if hub.leases.Load() != 2 {
		t.Fatal("a lease past its ttl was not renewed from the hub")
	}
}

func TestSocketMode(t *testing.T) {
	s, _ := startDesk(t, nil)
	st, err := os.Stat(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %o, want 0600", st.Mode().Perm())
	}
	again := &Server{Path: s.Path}
	if err := again.Listen(); err == nil {
		t.Fatal("a second desk took over a live socket")
	}
}

// TestSeatSweep: 127 5.4 deleter 2. A seat whose wrapper is gone is removed,
// a live one kept; an unclaimed dir goes after Grace. A seat outside the
// seat root is refused bad_seat.
// RED CONTROL: seatLive returning true -> the dead seat's dir survives.
func TestSeatSweep(t *testing.T) {
	now := time.Now()
	s, _ := startDesk(t, func(s *Server, _ *fakeHub) {
		s.Grace, s.Now = time.Minute, func() time.Time { return now }
	})
	mk := func(name string) string {
		d := filepath.Join(s.SeatRoot, name)
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
		return d
	}
	live, dead := mk("live"), mk("dead")
	mk("young")
	gone := exec.Command("true")
	if err := gone.Run(); err != nil {
		t.Fatal(err)
	}
	if tok := s.claimSeat(live, "grok", Peer{PID: int32(os.Getpid())}); tok != "" {
		t.Fatal(tok)
	}
	if tok := s.claimSeat(dead, "grok", Peer{PID: int32(gone.Process.Pid)}); tok != "" {
		t.Fatal(tok)
	}
	swept := s.Sweep()
	if strings.Join(swept, ",") != "dead" {
		t.Fatalf("swept %v, want [dead]", swept)
	}
	now = now.Add(2 * time.Minute)
	if swept := s.Sweep(); strings.Join(swept, ",") != "young" {
		t.Fatalf("after grace swept %v, want [young]", swept)
	}
	for _, d := range []string{live} { // the live seat stays
		if _, err := os.Stat(d); err != nil {
			t.Fatalf("%s removed: %v", d, err)
		}
	}
	outside := shortDir(t)
	if r := askReply(t, s.Path, request{Op: "lease", Kind: "grok", Seat: outside}); r.Error != TokBadSeat {
		t.Fatalf("seat outside the root: %+v", r)
	}
	if r := askReply(t, s.Path, request{Op: "lease", Kind: "grok", Seat: filepath.Join(s.SeatRoot, "..", "x")}); r.Error != TokBadSeat {
		t.Fatalf("seat path escaping the root: %+v", r)
	}
}

func TestEmptySeatsAtStart(t *testing.T) {
	d := shortDir(t)
	root := filepath.Join(d, "spool-seat")
	if err := os.MkdirAll(filepath.Join(root, "old", "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := (&Server{SeatRoot: root}).EmptySeats(); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(root)
	if len(ents) != 0 {
		t.Fatalf("seat root not emptied: %v", ents)
	}
}

func TestRootEquivalentGroups(t *testing.T) {
	etc := "root:x:0:\nsudo:x:27:user1\nusers:x:100:\ndocker:x:998:\nw1:x:2001:\n"
	if g := RootEquivalentIn(etc, []uint32{100, 2001}); g != "" {
		t.Fatalf("plain groups read as root-equivalent: %s", g)
	}
	if g := RootEquivalentIn(etc, []uint32{2001, 998}); g != "docker" {
		t.Fatalf("docker member: %q", g)
	}
	gids, err := ParseStatusGroups("Name:\tx\nGroups:\t27 100 \nX: 1\n")
	if err != nil || len(gids) != 2 || gids[0] != 27 {
		t.Fatalf("groups %v %v", gids, err)
	}
	if RootEquivalentIn(etc, gids) != "sudo" {
		t.Fatal("sudo member admitted")
	}
	if _, err := ParseStatusGroups("Name: x\n"); err == nil {
		t.Fatal("no Groups line accepted")
	}
}

func TestIdentityFile(t *testing.T) {
	p := filepath.Join(shortDir(t), "desk-x25519.key")
	a, err := LoadOrCreateIdentity(p)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadOrCreateIdentity(p)
	if err != nil || a.Recipient().String() != b.Recipient().String() {
		t.Fatalf("reload: %v", err)
	}
	if err := os.Chmod(p, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateIdentity(p); err == nil {
		t.Fatal("a 0644 identity file was used")
	}
}

func TestPayloadNeverPrintsKey(t *testing.T) {
	for _, s := range []string{Payload{Key: fakeKey}.String(), held{key: fakeKey}.String()} {
		if strings.Contains(s, fakeKey) {
			t.Fatalf("printed the key: %s", s)
		}
	}
}
