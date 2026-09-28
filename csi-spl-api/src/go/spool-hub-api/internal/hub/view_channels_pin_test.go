package hub_test

import (
	"flag"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
)

var updateViewChannels = flag.Bool("update-view-channels", false, "rewrite testdata/view_channels.golden")

// TestViewChannelsBytes pins GET /v1/view/channels byte for byte (times and
// cursors normalized) for a member of a private channel and an outsider,
// with and without a read cursor. Recorded before handleViewChannels was
// split into named steps (SPL-1029 round 2).
func TestViewChannelsBytes(t *testing.T) {
	r := newPrivacyRig(t)
	ts := regexp.MustCompile(`"\d{4}-\d\d-\d\dT[0-9:.]+Z"`)
	cur := regexp.MustCompile(`"last_cursor":"[^"]+"`)
	get := func(as, q string) string {
		t.Helper()
		code, _, body := viewGet(t, r.e, r.tid, "/v1/view/channels"+q, memberHeader, as)
		if code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", as, q, code, body)
		}
		return cur.ReplaceAllString(ts.ReplaceAllString(string(body), `"<TS>"`), `"last_cursor":"<C>"`)
	}
	// the lobby's own cursor as the read mark: its unread drops to 0
	_, _, raw := viewGet(t, r.e, r.tid, "/v1/view/channels", memberHeader, "HUM-1")
	lobbyCur := regexp.MustCompile(`"channel":"lobby"[^}]*"last_cursor":"([^"]+)"`).FindStringSubmatch(string(raw))
	if lobbyCur == nil {
		t.Fatalf("no lobby cursor in %s", raw)
	}
	var b strings.Builder
	for _, c := range []struct{ as, q string }{
		{"HUM-1", ""},
		{"HUM-2", ""},
		{"HUM-1", "?read=" + url.QueryEscape("lobby~"+lobbyCur[1])},
		{"HUM-1", "?read=" + url.QueryEscape("general~"+lobbyCur[1])}, // the lobby's alias
	} {
		b.WriteString("## " + c.as + " " + strings.SplitN(c.q, "~", 2)[0] + "\n" + get(c.as, c.q))
	}
	const path = "testdata/view_channels.golden"
	if *updateViewChannels {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if b.String() != string(want) {
		t.Fatalf("GET /v1/view/channels differs from %s:\n%s", path, b.String())
	}
}
