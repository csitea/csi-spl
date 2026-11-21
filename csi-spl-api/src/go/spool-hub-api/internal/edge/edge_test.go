package edge_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/edge"
)

func TestClientIP(t *testing.T) {
	r := func(xff ...string) *http.Request {
		q, _ := http.NewRequest(http.MethodGet, "http://h/", nil)
		q.RemoteAddr = "10.0.0.9:5555"
		for _, v := range xff {
			q.Header.Add("X-Forwarded-For", v)
		}
		return q
	}
	for _, c := range []struct {
		name string
		req  *http.Request
		hops int
		want string
	}{
		{"hops 0 is the peer, header ignored", r("192.0.2.1"), 0, "10.0.0.9"},
		{"one hop: last entry", r("192.0.2.1, 198.51.100.7"), 1, "198.51.100.7"},
		{"one hop, split across headers", r("192.0.2.1", "198.51.100.7"), 1, "198.51.100.7"},
		{"two hops: second from the right", r("192.0.2.1, 198.51.100.7, 35.191.0.1"), 2, "198.51.100.7"},
		{"too few entries: the peer", r("198.51.100.7"), 2, "10.0.0.9"},
		{"no header: the peer", r(), 1, "10.0.0.9"},
	} {
		if got := edge.ClientIP(c.req, c.hops); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestWindow(t *testing.T) {
	now := time.Unix(0, 0)
	w := edge.NewWindow(time.Minute, func() time.Time { return now })
	for i := 0; i < 2; i++ {
		if ok, _ := w.Allow("k", 2); !ok {
			t.Fatalf("attempt %d refused", i)
		}
	}
	ok, retry := w.Allow("k", 2)
	if ok || retry != time.Minute {
		t.Fatalf("third attempt: ok=%v retry=%v", ok, retry)
	}
	if ok, _ := w.Allow("other", 2); !ok {
		t.Fatal("keys share a bucket")
	}
	now = now.Add(time.Minute + time.Second)
	if ok, _ := w.Allow("k", 2); !ok {
		t.Fatal("the window never slid")
	}
}
