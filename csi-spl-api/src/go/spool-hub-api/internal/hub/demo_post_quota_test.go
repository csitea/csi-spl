package hub_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// postClock is a settable hub clock. It starts two days back at 01:00 UTC,
// so a test that crosses into the next UTC day stays in the past of the
// real clock (the seat's admission and stay are real time).
type postClock struct{ ns atomic.Int64 }

func newPostClock() *postClock {
	c := &postClock{}
	c.ns.Store(time.Now().UTC().Truncate(24 * time.Hour).Add(-47 * time.Hour).UnixNano())
	return c
}

func (c *postClock) now() time.Time      { return time.Unix(0, c.ns.Load()) }
func (c *postClock) add(d time.Duration) { c.ns.Add(int64(d)) }
func (c *postClock) opt(o *hub.Options)  { o.Now = c.now }
func postID(i int) string                { return fmt.Sprintf("5c0a7e11-0000-4000-8000-%012d", i) }
func postBody(i int) string              { return fmt.Sprintf("post %d", i) }
func isQuota(f map[string]any) bool {
	return f["error"] == "demo_quota" && f["status"] == float64(http.StatusTooManyRequests)
}
func isTooLarge(f map[string]any) bool {
	return f["error"] == "too_large" && f["status"] == float64(http.StatusRequestEntityTooLarge)
}
func sendPost(t *testing.T, c *websocket.Conn, i int) map[string]any {
	return sendBody(t, c, i, postBody(i))
}

// sendBody sends body as the i-th lobby post and returns the ack or error frame.
func sendBody(t *testing.T, c *websocket.Conn, i int, body string) map[string]any {
	t.Helper()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": postID(i), //nolint:errcheck
		"task_id": "lobby", "kind": "note", "body": body})
	return readType(t, c, "ack")
}

// notStored fails when msg i reached the store.
func notStored(t *testing.T, e *env, tid string, i int) {
	t.Helper()
	if _, _, err := e.st.MessageTimes(context.Background(), tid, postID(i)); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("refused post %d stored: %v", i, err)
	}
}

// specs/077 T012 (3.6): a demo_user's 10 posts of a minute are stored; the
// 11th answers 429 demo_quota and writes nothing; a resend of a stored post
// still re-acks; the next minute posts again.
// CONTROL: Options.DemoPostsPerMinute 11 stores the same 11th.
func TestDemoPostQuotaPerMinute(t *testing.T) {
	for _, tc := range []struct {
		name   string
		perMin int // 0 = the default 10
		want   bool
	}{{"default 10", 0, false}, {"CONTROL limit 11", 11, true}} {
		t.Run(tc.name, func(t *testing.T) {
			clk := newPostClock()
			e, demo := demoEnv(t, clk.opt, func(o *hub.Options) { o.DemoPostsPerMinute = tc.perMin })
			c := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
			for i := 1; i <= 10; i++ {
				if ack := sendPost(t, c, i); ack["type"] != "ack" {
					t.Fatalf("post %d: %v", i, ack)
				}
			}
			f := sendPost(t, c, 11)
			if tc.want {
				if f["type"] != "ack" {
					t.Fatalf("CONTROL: 11th post under limit 11: %v", f)
				}
				return
			}
			if !isQuota(f) {
				t.Fatalf("11th post: %v, want 429 demo_quota", f)
			}
			notStored(t, e, demo, 11)
			if ack := sendPost(t, c, 10); ack["type"] != "ack" {
				t.Fatalf("resend of post 10 at the limit: %v", ack)
			}
			clk.add(time.Minute)
			if ack := sendPost(t, c, 11); ack["type"] != "ack" {
				t.Fatalf("11th post in the next minute: %v", ack)
			}
		})
	}
}

// T012: 200 posts of a UTC day are stored, 10 a minute; the 201st answers
// 429 demo_quota in a fresh minute; the next UTC day posts again.
// CONTROL: Options.DemoPostsPerDay 201 stores the same 201st.
func TestDemoPostQuotaPerDay(t *testing.T) {
	for _, tc := range []struct {
		name   string
		perDay int // 0 = the default 200
		want   bool
	}{{"default 200", 0, false}, {"CONTROL limit 201", 201, true}} {
		t.Run(tc.name, func(t *testing.T) {
			clk := newPostClock()
			e, demo := demoEnv(t, clk.opt, func(o *hub.Options) {
				o.DemoPostsPerDay = tc.perDay
				o.DemoAgentTurns = 1000 // a #lobby post is an agent turn too (T013)
			})
			c := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
			for i := 1; i <= 200; i++ {
				if ack := sendPost(t, c, i); ack["type"] != "ack" {
					t.Fatalf("post %d: %v", i, ack)
				}
				if i%10 == 0 {
					clk.add(time.Minute)
				}
			}
			f := sendPost(t, c, 201)
			if tc.want {
				if f["type"] != "ack" {
					t.Fatalf("CONTROL: 201st post under limit 201: %v", f)
				}
				return
			}
			if !isQuota(f) || !strings.Contains(fmt.Sprint(f["detail"]), "a day") {
				t.Fatalf("201st post: %v, want 429 demo_quota per day", f)
			}
			notStored(t, e, demo, 201)
			clk.add(24 * time.Hour)
			if ack := sendPost(t, c, 201); ack["type"] != "ack" {
				t.Fatalf("201st post on the next day: %v", ack)
			}
		})
	}
}

// T012: the quota counts demo users only, per human. A developer of the demo
// workspace posts 15 in one minute; a demo_user's spent minute leaves the
// next demo_user's untouched.
func TestDemoPostQuotaOthersUnaffected(t *testing.T) {
	clk := newPostClock()
	e, demo := demoEnv(t, clk.opt, func(o *hub.Options) { o.DemoPostsPerMinute = 2 })
	dev := dialMember(t, e, demo, "", seat(t, e, demo, rbac.Developer))
	for i := 1; i <= 15; i++ {
		if ack := sendPost(t, dev, i); ack["type"] != "ack" {
			t.Fatalf("developer post %d: %v", i, ack)
		}
	}
	a := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
	for i := 101; i <= 102; i++ {
		if ack := sendPost(t, a, i); ack["type"] != "ack" {
			t.Fatalf("visitor a post %d: %v", i, ack)
		}
	}
	if f := sendPost(t, a, 103); !isQuota(f) {
		t.Fatalf("visitor a 3rd post: %v", f)
	}
	b := dialMember(t, e, demo, "", seat(t, e, demo, rbac.DemoUser))
	if ack := sendPost(t, b, 201); ack["type"] != "ack" {
		t.Fatalf("visitor b first post: %v", ack)
	}
}

// T012 (3.6): a demo_user's message body is at most 4 KiB on every write
// path - send, reply, edit and merge - and is refused 413 too_large with
// nothing written; a developer of the same workspace keeps the 64 KiB limit.
// CONTROL (by hand): delete the demoSend / demoBodyFits guard and this goes
// red on the 4097-byte send, edit or merge.
func TestDemoBodyCap(t *testing.T) {
	e, demo := demoEnv(t)
	vis := seat(t, e, demo, rbac.DemoUser)
	c := dialMember(t, e, demo, "", vis)
	fits, over := strings.Repeat("x", 4096), strings.Repeat("x", 4097)
	ack := sendBody(t, c, 1, fits)
	if ack["type"] != "ack" {
		t.Fatalf("4096-byte send: %v", ack)
	}
	if f := sendBody(t, c, 2, over); !isTooLarge(f) {
		t.Fatalf("4097-byte send: %v, want 413 too_large", f)
	}
	notStored(t, e, demo, 2)
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "msg_id": postID(3), "task_id": ack["task_id"], //nolint:errcheck
		"channel": "lobby", "is_parent": 0, "body": over})
	if f := readType(t, c, "ack"); !isTooLarge(f) {
		t.Fatalf("4097-byte reply: %v, want 413 too_large", f)
	}
	notStored(t, e, demo, 3)
	if st, out := patchEdit(t, e, demo, postID(1), vis, map[string]string{"body": over}); st != http.StatusRequestEntityTooLarge || out["error"] != "too_large" {
		t.Fatalf("4097-byte edit: %d %v", st, out)
	}
	if got := storedBody(t, e, demo, postID(1)); got != fits {
		t.Fatalf("refused edit changed the body to %d bytes", len(got))
	}
	if st, out := patchEdit(t, e, demo, postID(1), vis, map[string]string{"body": "short"}); st != http.StatusOK {
		t.Fatalf("short edit: %d %v", st, out)
	}
	src := postIn(t, c, lobby, strings.Repeat("y", 3000), 1)
	keep := postIn(t, c, lobby, strings.Repeat("z", 3000), 1)
	if st, out := merge(t, e, demo, src, keep, vis); st != http.StatusRequestEntityTooLarge || out["error"] != "too_large" {
		t.Fatalf("6 KiB merge: %d %v", st, out)
	}
	if _, _, err := e.st.MessageTimes(context.Background(), demo, src); err != nil {
		t.Fatalf("refused merge deleted the source: %v", err)
	}

	dev := seat(t, e, demo, rbac.Developer)
	d := dialMember(t, e, demo, "", dev)
	big := strings.Repeat("x", 8<<10)
	if ack := sendBody(t, d, 10, big); ack["type"] != "ack" {
		t.Fatalf("developer 8 KiB send: %v", ack)
	}
	if st, out := patchEdit(t, e, demo, postID(10), dev, map[string]string{"body": big + "!"}); st != http.StatusOK {
		t.Fatalf("developer 8 KiB edit: %d %v", st, out)
	}
}
