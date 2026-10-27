package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B2 (SPL-3888, rdb 0236): a box announces its file streams and
// pushes their masked lines over its authenticated session. Red on
// origin/master before SPL-3888: no file_streams lane op, every frame is
// answered bad_frame by the fleet lane map.

type fsRig struct {
	e      *env
	w, w2  string
	a, a2  *box
	limits store.FileStreamLimits
}

func newFSRig(t *testing.T, lim store.FileStreamLimits, mut ...func(*hub.Options)) *fsRig {
	t.Helper()
	r := &fsRig{}
	r.e = rbacEnv(t, append([]func(*hub.Options){func(o *hub.Options) {
		lim.MaxWorkspaces = 1 << 20 // the Postgres test database keeps other runs' streams
		o.FileStreamLimits = lim
	}}, mut...)...)
	r.w, _ = r.e.tenant()
	r.w2, _ = r.e.tenant()
	r.a, r.a2 = r.e.box(r.w, "box-a"), r.e.box(r.w2, "box-a")
	r.e.pin(r.w, r.a)
	r.e.pin(r.w2, r.a2)
	return r
}

func (r *fsRig) lane(t *testing.T, b *box, op, payload string) (wire.FileStreamsAckFrame, error) {
	t.Helper()
	raw, err := b.c.Lane(context.Background(), op, "", json.RawMessage(payload))
	var ack wire.FileStreamsAckFrame
	if err == nil {
		if err := json.Unmarshal(raw, &ack); err != nil {
			t.Fatalf("ack %s: %v", raw, err)
		}
	}
	return ack, err
}

func fsAnnounce(keys ...string) string {
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = fmt.Sprintf(`{"stream_key":%q,"path":"/var/log/%s.log","state":"following"}`, k, k)
	}
	return `{"streams":[` + strings.Join(parts, ",") + `]}`
}

func fsPushBody(key string, from, n int, at time.Time) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = fmt.Sprintf(`{"seq":%d,"at":%q,"text":"line %d","marker":false}`, from+i, at.UTC().Format(time.RFC3339), from+i)
	}
	return fmt.Sprintf(`{"stream_key":%q,"lines":[%s],"dropped":0,"redactions":{}}`, key, strings.Join(parts, ","))
}

func (r *fsRig) lines(t *testing.T, tid, key string) []store.FileStreamLine {
	t.Helper()
	fs := r.e.st.(store.FileStreamStore)
	all, err := fs.ListFileStreams(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range all {
		if f.StreamKey == key {
			ls, err := fs.FileStreamLines(context.Background(), tid, f.ID, store.FileStreamLinesQuery{})
			if err != nil {
				t.Fatal(err)
			}
			return ls
		}
	}
	return nil
}

// TestFileStreamsAnnounceAndPush: the follower's two frames, acked with the
// fields the follower reads (type ack); a re-sent push is acked and stored
// once; a push before its announce is 409 not_announced.
func TestFileStreamsAnnounceAndPush(t *testing.T) {
	r := newFSRig(t, store.FileStreamLimits{})
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 1, time.Now())); err == nil || !strings.Contains(err.Error(), "not_announced") {
		t.Fatalf("push before announce: %v, want not_announced", err)
	}
	ack, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app"))
	if err != nil || ack.Type != "ack" || len(ack.Streams) != 1 || ack.Streams[0].State != wire.FileStreamFollowing {
		t.Fatalf("announce ack = %+v %v", ack, err)
	}
	for i := 0; i < 2; i++ {
		ack, err = r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 3, time.Now()))
		if err != nil || ack.Type != "ack" || ack.StreamKey != "app" || ack.AckedSeq != 3 || ack.Inserted != 3-3*i {
			t.Fatalf("push %d ack = %+v %v", i, ack, err)
		}
	}
	if ls := r.lines(t, r.w, "app"); len(ls) != 3 || ls[2].Text != "line 3" {
		t.Fatalf("stored = %+v", ls)
	}
}

// TestFileStreamsBoxIsTheSessions (case C11): box-a of W pushes; the rows
// are W's and box-a's, W2's same-named box sees none, and a frame that
// names a box or a tenant is refused. CONTROL: a box taken from the frame
// would store the row under the named box.
func TestFileStreamsBoxIsTheSessions(t *testing.T) {
	r := newFSRig(t, store.FileStreamLimits{})
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 2, time.Now())); err != nil {
		t.Fatal(err)
	}
	if ls := r.lines(t, r.w2, "app"); len(ls) != 0 {
		t.Fatalf("W2 got W's lines: %+v", ls)
	}
	all, _ := r.e.st.(store.FileStreamStore).ListFileStreams(context.Background(), r.w)
	if len(all) != 1 || all[0].Box != "box-a" || all[0].Tenant != r.w {
		t.Fatalf("W's streams = %+v", all)
	}
	for name, body := range map[string]string{
		"box":    `{"stream_key":"app","box":"box-b","lines":[{"seq":9,"at":"2026-10-27T10:00:00Z","text":"x","marker":false}]}`,
		"tenant": `{"stream_key":"app","tenant_id":"` + r.w2 + `","lines":[{"seq":9,"at":"2026-10-27T10:00:00Z","text":"x","marker":false}]}`,
	} {
		if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, body); err == nil || !strings.Contains(err.Error(), "bad_file_stream") {
			t.Errorf("a frame naming its %s: %v, want bad_file_stream", name, err)
		}
	}
	if _, err := r.lane(t, r.a2, wire.FileStreamsPushOp, fsPushBody("app", 1, 1, time.Now())); err == nil || !strings.Contains(err.Error(), "not_announced") {
		t.Fatalf("W2's box-a into W's stream: %v, want not_announced", err)
	}
}

// TestFileStreamsLimitsStoreNothing (case C23): a push over 1000 lines is
// 413 too_large, one over twice the line rate 429 rate_limited, and neither
// stores a line. CONTROL: store first, check after would leave the first
// lines of the refused push.
func TestFileStreamsLimitsStoreNothing(t *testing.T) {
	r := newFSRig(t, store.FileStreamLimits{RatePerMin: 5})
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, wire.FileStreamLinesPerPush+1, now)); err == nil || !strings.Contains(err.Error(), "too_large") {
		t.Fatalf("1001 lines: %v, want too_large", err)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 11, now)); err == nil || !strings.Contains(err.Error(), "rate_limited") {
		t.Fatalf("11 lines in a minute at rate 5: %v, want rate_limited", err)
	}
	if ls := r.lines(t, r.w, "app"); len(ls) != 0 {
		t.Fatalf("a refused push stored %d lines", len(ls))
	}
}
