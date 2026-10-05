package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// stayRig is a session-door hub with the demo on, a fake clock for the hub
// (the sweep's now) and a signed-in browser per visitor.
type stayRig struct {
	r    *doorRig
	demo string
	mu   sync.Mutex
	now  time.Time
	srv  *hub.Server
}

func (s *stayRig) clock() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.now
}

func (s *stayRig) set(at time.Time) {
	s.mu.Lock()
	s.now = at
	s.mu.Unlock()
}

func newStayRig(t *testing.T) *stayRig {
	t.Helper()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	s := &stayRig{demo: "t" + hex.EncodeToString(b), now: time.Now().UTC()}
	s.r = newDoorRig(t, func(o *hub.Options) { o.DemoWorkspace = s.demo; o.Now = s.clock })
	s.srv = s.r.e.srv
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := s.r.e.st.CreateTenant(context.Background(), store.Tenant{ID: s.demo, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	ownedBy(t, s.r.e, s.demo, "owner-of-"+s.demo)
	return s
}

// visitor seats a fresh person in the demo workspace with role, signs them in
// and returns their browser and HUM-*.
func (s *stayRig) visitor(t *testing.T, role string) (*http.Client, string) {
	t.Helper()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	email := "v" + hex.EncodeToString(b) + "@example.com"
	invite(t, s.r.e, s.demo, email, role)
	signInAs(t, s.r, s.demo, fakeidp.Person{Subject: "s-" + email, Email: email, EmailVerified: true, Name: "FirstName LastName"})
	return s.r.browser, s.r.session(t).HumanID
}

// endsAt sets the seat's end (access_until).
func (s *stayRig) endsAt(t *testing.T, hum string, at time.Time) {
	t.Helper()
	if err := s.r.e.st.(store.MemberAccess).SetMemberAccessUntil(context.Background(), s.demo, hum, &at); err != nil {
		t.Fatal(err)
	}
}

// me is GET /v1/view/me in the demo workspace through browser c.
func (s *stayRig) me(t *testing.T, c *http.Client) (int, string) {
	t.Helper()
	keep := s.r.browser
	s.r.browser = c
	defer func() { s.r.browser = keep }()
	return s.r.req(t, http.MethodGet, s.demo, "/v1/view/me", nil, nil)
}

// socket opens c's WUI socket in the demo workspace, past the welcome.
func (s *stayRig) socket(t *testing.T, c *http.Client) *websocket.Conn {
	t.Helper()
	ctx := context.Background()
	ws, _, err := websocket.Dial(ctx, "ws://"+s.demo+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: c})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })                       //nolint:errcheck
	wsjson.Write(ctx, ws, map[string]string{"type": "hello"}) //nolint:errcheck
	readType(t, ws, "welcome")
	return ws
}

// closedWith reads ws until it closes and returns the close status and reason.
func closedWith(t *testing.T, ws *websocket.Conn) (websocket.StatusCode, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f map[string]any
		err := wsjson.Read(ctx, ws, &f)
		var ce websocket.CloseError
		if errors.As(err, &ce) {
			return ce.Code, ce.Reason
		}
		if err != nil {
			t.Fatalf("socket did not close: %v", err)
		}
	}
}

// specs/077 T009 (FR-005): after the seat's end the door answers 401
// demo_expired and the next socket frame gets a demo_expired error and close
// 4401; before it the visitor reads. A developer of the demo workspace whose
// access ended is no ended demo visit: the plain refusal. CONTROL (run by
// hand, recorded in the T009 row): without doorDemoExpired the ended visitor
// gets 401 view_door.
func TestDemoStayDoor(t *testing.T) {
	s := newStayRig(t)
	v, hum := s.visitor(t, rbac.DemoUser)
	if code, body := s.me(t, v); code != http.StatusOK || !strings.Contains(body, `"role":"`+rbac.DemoUser+`"`) {
		t.Fatalf("CONTROL: the visitor reads before the end: %d %s", code, body)
	}
	ws := s.socket(t, v)
	s.endsAt(t, hum, time.Now().Add(-time.Minute))
	for _, path := range []string{"/v1/view/me", "/v1/view/topics"} {
		keep := s.r.browser
		s.r.browser = v
		code, body := s.r.req(t, http.MethodGet, s.demo, path, nil, nil)
		s.r.browser = keep
		if code != http.StatusUnauthorized || errToken([]byte(body)) != "demo_expired" {
			t.Fatalf("GET %s after the end: %d %s, want 401 demo_expired", path, code, body)
		}
	}
	wsjson.Write(context.Background(), ws, map[string]any{"type": "subscribe", "task_id": "lobby"}) //nolint:errcheck
	if f := readType(t, ws, "subscribed"); f["error"] != "demo_expired" || f["status"] != float64(http.StatusUnauthorized) {
		t.Fatalf("frame after the end: %v, want a 401 demo_expired error", f)
	}
	if code, reason := closedWith(t, ws); code != wire.CloseUnauthorized || reason != "demo_expired" {
		t.Fatalf("socket after the end: %d %q, want 4401 demo_expired", code, reason)
	}
	dev, dhum := s.visitor(t, rbac.Developer)
	s.endsAt(t, dhum, time.Now().Add(-time.Minute))
	if code, body := s.me(t, dev); errToken([]byte(body)) == "demo_expired" || code == http.StatusOK {
		t.Fatalf("a developer whose access ended: %d %s, want the plain refusal", code, body)
	}
}

// specs/077 T009 (FR-005, Q10): the 5-minute sweep closes the ended
// visitor's sockets (4401 demo_expired, no frame needed), drops the seat,
// the human and its avatar, and leaves a running visitor alone; the swept
// session still reads 401 demo_expired. The hub's fake clock decides the
// end. CONTROL (run by hand, recorded in the T009 row): without
// closeMemberSockets the ended visitor's socket stays open and this fails.
func TestDemoStaySweepClosesSockets(t *testing.T) {
	ctx := context.Background()
	s := newStayRig(t)
	base := s.clock()
	gone, ghum := s.visitor(t, rbac.DemoUser)
	stay, shum := s.visitor(t, rbac.DemoUser)
	gws, sws := s.socket(t, gone), s.socket(t, stay) // open while both seats run
	s.endsAt(t, ghum, base.Add(-time.Minute))
	s.endsAt(t, shum, base.Add(3*time.Hour))
	pic := sha256.Sum256([]byte(ghum + s.demo))
	avatar := hex.EncodeToString(pic[:])
	bs := blob.Dir{Root: s.r.e.blobs}
	key, _ := blob.AvatarKey(avatar)
	if err := bs.Put(ctx, key, []byte("png")); err != nil {
		t.Fatal(err)
	}
	if err := s.r.e.st.(store.Humans).SetAvatar(ctx, ghum, avatar); err != nil {
		t.Fatal(err)
	}

	s.srv.SweepDemo(ctx)
	if code, reason := closedWith(t, gws); code != wire.CloseUnauthorized || reason != "demo_expired" {
		t.Fatalf("ended visitor's socket: %d %q, want 4401 demo_expired", code, reason)
	}
	wsjson.Write(ctx, sws, map[string]any{"type": "subscribe", "task_id": "lobby"}) //nolint:errcheck
	if f := readType(t, sws, "subscribed"); f["type"] != "subscribed" {
		t.Fatalf("running visitor after the sweep: %v", f)
	}
	if code, body := s.me(t, gone); code != http.StatusUnauthorized || errToken([]byte(body)) != "demo_expired" {
		t.Fatalf("swept visitor: %d %s, want 401 demo_expired", code, body)
	}
	if _, err := s.r.e.st.(store.Humans).MemberRole(ctx, ghum, s.demo); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("swept seat: %v", err)
	}
	ms, err := s.r.e.st.(store.MemberDirectory).ListMembers(ctx, s.demo)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(ms, func(m store.Member) bool { return m.HumanID == ghum }) {
		t.Fatal("the swept seat is still listed")
	}
	if ok, _ := bs.Exists(ctx, key); ok {
		t.Fatal("the swept visitor's avatar is still stored")
	}
	if code, _ := s.me(t, stay); code != http.StatusOK {
		t.Fatalf("running visitor reads: %d", code)
	}

	// The fake clock reaches the running visitor's end: the next sweep ends it.
	s.set(base.Add(3 * time.Hour))
	s.srv.SweepDemo(ctx)
	if code, reason := closedWith(t, sws); code != wire.CloseUnauthorized || reason != "demo_expired" {
		t.Fatalf("second visitor at its end: %d %q", code, reason)
	}
}

// GET /v1/demo shows the configured stay (SPOOL_HUB_DEMO_MAX_STAY).
func TestDemoStayShown(t *testing.T) {
	for _, c := range []struct {
		stay time.Duration
		want string
	}{{0, "3h"}, {90 * time.Minute, "1h30m"}, {45 * time.Minute, "45m"}} {
		e, demo := demoEnv(t, func(o *hub.Options) { o.DemoMaxStay = c.stay })
		code, body := call(t, e, demo, http.MethodGet, "/v1/demo", "", nil)
		if code != http.StatusOK || body["max_stay"] != c.want {
			t.Fatalf("stay %v: %d %v, want max_stay %s", c.stay, code, body, c.want)
		}
	}
}
