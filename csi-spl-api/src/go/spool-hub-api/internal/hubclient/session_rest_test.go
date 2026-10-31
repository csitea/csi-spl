package hubclient

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r7-04: the session's tail, rsp_count, token and REST (pins, files) paths.

func dialOps(t *testing.T, h *opsHub, role string) (*Client, *Session) {
	t.Helper()
	c := opsClient(t, h)
	s, err := c.Dial(context.Background(), role)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return c, s
}

func tailHub(t *testing.T, envs ...[]byte) *opsHub {
	return &opsHub{reply: func(f wire.Frame) []wire.Frame {
		if f.Type != wire.TTail {
			return nil
		}
		var out []wire.Frame
		for _, e := range envs {
			out = append(out, wire.Frame{Type: wire.TTailMsg, Env: e})
		}
		out = append(out, wire.Frame{Type: wire.TTailMsg, Env: []byte(`"not an envelope"`)}) // skipped
		return append(out, wire.Frame{Type: wire.TTailEnd})
	}}
}

func TestTailStreamsStoredEnvelopes(t *testing.T) {
	p := newPeer(t, "box-b")
	m1, m2 := note("c-007", "c-008", "task", "one"), note("c-008", "c-007", "result", "two")
	h := tailHub(t, envRaw(t, p, "box-a", "", m1), envRaw(t, p, "box-a", "", m2))
	_, s := dialOps(t, h, wire.RoleCLI)
	var ids []string
	n, err := s.Tail(context.Background(), "task-1", false, func(e *wire.Envelope) {
		in, _ := e.Inner()
		ids = append(ids, in.MsgID)
	})
	if err != nil || n != 2 || len(ids) != 2 || ids[0] != m1.MsgID || ids[1] != m2.MsgID {
		t.Fatalf("n %d err %v ids %v", n, err, ids)
	}
	if f := h.frames(wire.TTail); len(f) != 1 || f[0].TaskID != "task-1" || f[0].Follow {
		t.Errorf("tail frames %+v", f)
	}
}

// With follow, tail_end does not end the call; a ctx that ends after it is a
// clean stop, not an error.
func TestTailFollowStopsCleanOnCancel(t *testing.T) {
	p := newPeer(t, "box-b")
	h := tailHub(t, envRaw(t, p, "box-a", "", note("c-007", "c-008", "task", "one")))
	_, s := dialOps(t, h, wire.RoleCLI)
	ctx, cancel := context.WithCancel(context.Background())
	got := make(chan struct{}, 1)
	go func() {
		<-got
		time.Sleep(50 * time.Millisecond) // past the tail_end
		cancel()
	}()
	n, err := s.Tail(ctx, "task-1", true, func(*wire.Envelope) { got <- struct{}{} })
	if err != nil || n != 1 {
		t.Fatalf("n %d err %v", n, err)
	}
}

func TestTailRefusedAndClosed(t *testing.T) {
	h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
		return []wire.Frame{{Type: wire.TError, Error: "forbidden", Status: 403}}
	}}
	_, s := dialOps(t, h, wire.RoleCLI)
	var he *HubError
	if _, err := s.Tail(context.Background(), "t", false, func(*wire.Envelope) {}); !errors.As(err, &he) || he.Token != "forbidden" {
		t.Fatalf("got %v", err)
	}
	s.Close()
	<-s.Done()
	if _, err := s.Tail(context.Background(), "t", false, func(*wire.Envelope) {}); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("tail on a closed session: %v", err)
	}
}

func TestRSPCount(t *testing.T) {
	cases := []struct {
		name  string
		reply wire.Frame
		n     int
		want  string // "" = success
	}{
		{"answered", wire.Frame{Type: wire.TTailEnd, RSPCount: true, Count: 2}, 2, ""},
		{"older hub, no echo", wire.Frame{Type: wire.TTailEnd, Count: 5}, 0, "does not answer rsp_count"},
		{"older hub streams", wire.Frame{Type: wire.TTailMsg}, 0, "streamed the tail"},
		{"refused", wire.Frame{Type: wire.TError, Error: "forbidden", Status: 403}, 0, "forbidden"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
				if f.Type != wire.TTail || !f.RSPCount {
					return nil
				}
				return []wire.Frame{tc.reply}
			}}
			_, s := dialOps(t, h, wire.RoleCLI)
			n, err := s.RSPCount(context.Background(), "task-1")
			if tc.want == "" && (err != nil || n != tc.n) {
				t.Fatalf("n %d err %v", n, err)
			}
			if tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
				t.Fatalf("got %d %v, want %q", n, err, tc.want)
			}
		})
	}
}

// SPL-4444: AgentCount asks agent_count and accepts only a tail_end that
// echoes it; an rsp_count echo is not an answer.
func TestAgentCount(t *testing.T) {
	cases := []struct {
		name  string
		reply wire.Frame
		n     int
		want  string // "" = success
	}{
		{"answered", wire.Frame{Type: wire.TTailEnd, AgentCount: true, Count: 4}, 4, ""},
		{"older hub, no echo", wire.Frame{Type: wire.TTailEnd, Count: 5}, 0, "does not answer agent_count"},
		{"the other count", wire.Frame{Type: wire.TTailEnd, RSPCount: true, Count: 1}, 0, "does not answer agent_count"},
		{"older hub streams", wire.Frame{Type: wire.TTailMsg}, 0, "streamed the tail"},
		{"refused", wire.Frame{Type: wire.TError, Error: "forbidden", Status: 403}, 0, "forbidden"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
				if f.Type != wire.TTail || !f.AgentCount || f.RSPCount {
					return nil
				}
				return []wire.Frame{tc.reply}
			}}
			_, s := dialOps(t, h, wire.RoleCLI)
			n, err := s.AgentCount(context.Background(), "task-1")
			if tc.want == "" && (err != nil || n != tc.n) {
				t.Fatalf("n %d err %v", n, err)
			}
			if tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
				t.Fatalf("got %d %v, want %q", n, err, tc.want)
			}
		})
	}
}

func TestRSPCountNoReply(t *testing.T) {
	h := &opsHub{reply: func(wire.Frame) []wire.Frame { return nil }}
	c, s := dialOps(t, h, wire.RoleCLI)
	c.ReadyTimeout = 200 * time.Millisecond
	if _, err := s.RSPCount(context.Background(), "t"); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("got %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c.ReadyTimeout = 5 * time.Second
	if _, err := s.RSPCount(ctx, "t"); err == nil {
		t.Fatal("a cancelled ctx returned no error")
	}
}

// The welcome token is live for an hour: UploadToken returns it without a
// token frame; Probe carries it as the bearer of GET /v1/pins?probe=1.
func TestUploadTokenAndProbe(t *testing.T) {
	h := &opsHub{}
	_, s := dialOps(t, h, wire.RoleCLI)
	tok, err := s.UploadToken(context.Background())
	if err != nil || tok != "tok" {
		t.Fatalf("token %q err %v", tok, err)
	}
	if n := len(h.frames(wire.TToken)); n != 0 {
		t.Errorf("%d token frames for a live token", n)
	}
	if err := s.Probe(context.Background()); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.paths) != 1 || h.paths[0] != "/v1/pins?probe=1" || h.auth[0] != "Bearer tok" {
		t.Errorf("REST calls %v auth %v", h.paths, h.auth)
	}
}

// A 401 door is the redeploy signal (orphaned); a 5xx is unreachable.
func TestProbeRefusals(t *testing.T) {
	h := &opsHub{}
	_, s := dialOps(t, h, wire.RoleCLI)
	h.setREST(http.StatusUnauthorized, "door")
	err := s.Probe(context.Background())
	if !orphaned(err) {
		t.Fatalf("401 door: orphaned(%v) = false", err)
	}
	h.setREST(http.StatusBadGateway, "upstream")
	if err := s.Probe(context.Background()); !errors.Is(err, ErrUnreachable) || orphaned(err) {
		t.Fatalf("502: %v", err)
	}
}

func TestUploadAndFetchFile(t *testing.T) {
	h := &opsHub{}
	c, s := dialOps(t, h, wire.RoleCLI)
	src := filepath.Join(t.TempDir(), "a.txt")
	if err := os.WriteFile(src, []byte("attachment bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err := files.PutFile(c.Cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.UploadFile(context.Background(), a.FileID); err != nil {
		t.Fatal(err)
	}
	h.mu.Lock()
	up := h.files[a.FileID]
	h.mu.Unlock()
	if string(up) != "attachment bytes" {
		t.Fatalf("hub holds %q", up)
	}
	if err := s.UploadFile(context.Background(), "0000"); err == nil || !strings.Contains(err.Error(), "not in the local store") {
		t.Fatalf("missing blob: %v", err)
	}

	// FetchFile always downloads; fetchFile skips a blob already here
	id := h.putFile([]byte("from the hub"))
	if err := s.FetchFile(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if raw, err := os.ReadFile(filepath.Join(c.Cfg.FilesDir(), id)); err != nil || string(raw) != "from the hub" {
		t.Fatalf("fetched %q %v", raw, err)
	}
	h.setREST(http.StatusInternalServerError, "")
	if err := s.fetchFile(context.Background(), id); err != nil {
		t.Fatalf("fetchFile re-downloaded a present blob: %v", err)
	}
	h.setREST(0, "")

	var he *HubError
	if err := s.FetchFile(context.Background(), blobID([]byte("nobody has this"))); !errors.As(err, &he) || he.Token != "not_found" {
		t.Fatalf("absent file: %v", err)
	}
}

// Bytes that do not hash to the asked id are never kept.
func TestFetchFileHashMismatch(t *testing.T) {
	h := &opsHub{}
	c, s := dialOps(t, h, wire.RoleCLI)
	lie := blobID([]byte("what was asked"))
	h.mu.Lock()
	h.files[lie] = []byte("something else")
	h.mu.Unlock()
	if err := s.FetchFile(context.Background(), lie); !errors.Is(err, files.ErrHashMismatch) {
		t.Fatalf("got %v", err)
	}
	ents, _ := os.ReadDir(c.Cfg.FilesDir())
	if len(ents) != 0 {
		t.Errorf("files left behind: %v", ents)
	}
}

// SyncPins installs new pins, keeps a same-key pin, skips an invalid box id,
// and reports (without clobbering) a pin the hub rotated.
func TestSyncPins(t *testing.T) {
	b, d, x := newPeer(t, "box-b"), newPeer(t, "box-d"), newPeer(t, "box-x")
	h := &opsHub{pins: []wire.PinEntry{b.pin, d.pin, {BoxID: "not a box", PubKey: "AAAA"}}}
	c, s := dialOps(t, h, wire.RoleCLI)
	if err := s.SyncPins(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, box := range []string{"box-b", "box-d"} {
		if _, err := sign.LoadPin(c.Cfg.PinsDir, box); err != nil {
			t.Errorf("%s not pinned: %v", box, err)
		}
	}
	if err := s.SyncPins(context.Background()); err != nil { // same keys: no-op
		t.Fatalf("second sync: %v", err)
	}

	// the hub now says box-b has x's key
	h.setPins(wire.PinEntry{BoxID: "box-b", PubKey: x.pin.PubKey}, d.pin)
	err := s.SyncPins(context.Background())
	var he *HubError
	if !errors.As(err, &he) || he.Token != "pin_conflict" || s.pinConflict == nil {
		t.Fatalf("got %v", err)
	}
	if pub, err := sign.LoadPin(c.Cfg.PinsDir, "box-b"); err != nil || base64.StdEncoding.EncodeToString(pub) != b.pin.PubKey {
		t.Errorf("the local box-b pin was clobbered (%v)", err)
	}
}
