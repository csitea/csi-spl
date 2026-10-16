package hubclient

// SPL-2165: the fallback queue reports its depth, its oldest entry's age and
// its last flush, and WARNs at the cnf threshold.

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// deadURL is a hub address that refuses every dial.
func deadURL(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(nil)
	u := srv.URL
	srv.Close()
	return u
}

// queueDown sends n messages while the hub is down and returns their pending
// files, oldest first.
func queueDown(t *testing.T, c *Client, n int) []string {
	t.Helper()
	priv, err := sign.LoadPrivate(c.Cfg.KeysDir, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for i := 0; i < n; i++ {
		m := compose(t, c, fmt.Sprintf("queued %d", i))
		m.TS = fmt.Sprintf("2026-10-16T10:00:0%dZ", i)
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", m)
		if err != nil {
			t.Fatal(err)
		}
		p, err := c.writePending(m, env, Claims{})
		if err != nil {
			t.Fatal(err)
		}
		if d, err := c.sendNow(context.Background(), env, m, p, Claims{}); err != nil || d != wire.DeliveryPending {
			t.Fatalf("send with the hub down: %q %v, want pending", d, err)
		}
		out = append(out, p)
	}
	return out
}

func TestQueueHealthDepthAgeWarnAndFlush(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	live := c.Cfg.HubURL
	c.Cfg.HubURL = deadURL(t)
	now := time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)
	c.Now = func() time.Time { return now }
	c.QueueWarnAfter = 15 * time.Minute
	var logs syncBuf
	c.Log = zerolog.New(&logs)

	files := queueDown(t, c, 3)
	if err := os.Chtimes(files[0], now.Add(-10*time.Minute), now.Add(-10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	q, err := c.QueueHealth()
	if err != nil || q.Depth != 3 || q.OldestAgeS != 600 || q.Warn || q.WarnAfterS != 900 || q.LastFlush != nil {
		t.Fatalf("hub down, 3 queued, oldest 10 min: %+v %v", q, err)
	}
	c.logQueue()
	if s := logs.String(); !strings.Contains(s, `"level":"info"`) || !strings.Contains(s, `"depth":3`) || !strings.Contains(s, `"oldest_age_s":600`) {
		t.Fatalf("below the threshold: want one INFO line with depth and age, got %s", s)
	}

	// at the threshold: WARN
	if err := os.Chtimes(files[0], now.Add(-15*time.Minute), now.Add(-15*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if q, _ = c.QueueHealth(); !q.Warn || q.OldestAgeS != 900 {
		t.Fatalf("at the threshold: %+v, want warn", q)
	}
	c.logQueue()
	if s := logs.String(); !strings.Contains(s, `"level":"warn"`) || !strings.Contains(s, "older than the cnf threshold") {
		t.Fatalf("at the threshold: want a WARN line, got %s", s)
	}

	// no threshold in cnf: never a WARN, however old
	c.QueueWarnAfter = 0
	if q, _ = c.QueueHealth(); q.Warn || q.WarnAfterS != 0 {
		t.Fatalf("no threshold: %+v, want no warn", q)
	}

	// the hub is back: flush -> depth 0 and the flush line
	c.Cfg.HubURL = live
	sess, err := c.Dial(context.Background(), wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	if n, err := sess.Flush(context.Background()); err != nil || n != 3 {
		t.Fatalf("flush: %d %v", n, err)
	}
	q, err = c.QueueHealth()
	if err != nil || q.Depth != 0 || q.OldestAgeS != 0 || q.OldestAt != "" || q.Warn {
		t.Fatalf("after the flush: %+v %v", q, err)
	}
	if f := q.LastFlush; f == nil || f.Flushed != 3 || f.Left != 0 || f.Error != "" || f.At != "2026-10-16T12:00:00Z" {
		t.Fatalf("last flush = %+v", q.LastFlush)
	}
	if s := logs.String(); !strings.Contains(s, "fallback queue flushed") || !strings.Contains(s, `"flushed":3`) {
		t.Fatalf("want the flush line, got %s", s)
	}
}

// A flush that stops keeps its error for hub-queue, and logs a WARN.
func TestQueueHealthRecordsFailedFlush(t *testing.T) {
	c := testClient(t)
	var logs syncBuf
	c.Log = zerolog.New(&logs)
	p := filepath.Join(c.pendingDir(), "20261016T100000Z--6e21fc60-5143-4c09-ada5-9c416e23c673.json")
	if err := writeAtomic(p, []byte("{not an envelope")); err != nil {
		t.Fatal(err)
	}
	if _, err := (&Session{c: c}).Flush(context.Background()); err == nil {
		t.Fatal("want the flush to fail")
	}
	q, err := c.QueueHealth()
	if err != nil || q.Rejected != 1 || q.LastFlush == nil || q.LastFlush.Error == "" || q.LastFlush.Flushed != 0 {
		t.Fatalf("after a failed flush: %+v (%+v) %v", q, q.LastFlush, err)
	}
	if s := logs.String(); !strings.Contains(s, "fallback queue flush stopped") || !strings.Contains(s, `"level":"warn"`) {
		t.Fatalf("want the WARN flush line, got %s", s)
	}
}

// hub-run logs the queue on its period while the hub is DOWN - when it grows.
func TestRunLogsQueueWhileHubDown(t *testing.T) {
	c := testClient(t)
	c.Cfg.HubURL = deadURL(t)
	c.Cfg.Tenant = "t1"
	c.Cfg.SubmitSocket = shortSock(t)
	c.QueueLogEvery = 20 * time.Millisecond
	queueDown(t, c, 2)
	var logs syncBuf
	c.Log = zerolog.New(&logs)
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if s := logs.String(); strings.Count(s, `"message":"fallback queue"`) < 2 || !strings.Contains(s, `"depth":2`) {
		t.Fatalf("want periodic queue lines with depth 2 while down, got %s", s)
	}
}

func TestParseMinutes(t *testing.T) {
	for in, want := range map[string]time.Duration{"": 0, "0": 0, "15": 15 * time.Minute, " 5 ": 5 * time.Minute, "90s": 90 * time.Second} {
		if got, err := ParseMinutes(in); err != nil || got != want {
			t.Errorf("ParseMinutes(%q) = %v %v, want %v", in, got, err, want)
		}
	}
	if _, err := ParseMinutes("soon"); err == nil {
		t.Error("ParseMinutes(soon): want an error")
	}
}
