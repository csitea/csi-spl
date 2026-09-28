package hub_test

import (
	"encoding/json"
	"net/http"
	"net/url"
	"reflect"
	"testing"
	"time"
)

// Pins of GET /v1/view/topics/{task_id}, taken before handleViewTopic was
// split into named steps (SPL-1029 round 2): the query refusals word for
// word, and that walking either order with limit=1 returns the whole topic
// in that order.
func TestViewTopicQueryAndPaging(t *testing.T) {
	r := newPrivacyRig(t)
	task := uuidV4()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for i := 0; i < 3; i++ {
		putRow(t, r.e, r.tid, task, "lobby", "HUM-1", "CLE-07", "step", now.Add(time.Duration(i)*time.Second))
	}
	type page struct {
		Messages []struct {
			MsgID  string `json:"msg_id"`
			Cursor string `json:"cursor"`
		} `json:"messages"`
		Next  *string `json:"next"`
		Error string  `json:"error"`
	}
	get := func(path string) (int, page) {
		t.Helper()
		code, _, body := viewGet(t, r.e, r.tid, path, memberHeader, "HUM-1")
		var p page
		json.Unmarshal(body, &p) //nolint:errcheck
		return code, p
	}
	base := "/v1/view/topics/" + task
	for _, c := range []struct {
		q     string
		code  int
		token string
	}{
		{"?order=sideways", http.StatusBadRequest, "bad_json"},
		{"?order=desc&after=x", http.StatusBadRequest, "bad_json"},
		{"?order=asc&before=x", http.StatusBadRequest, "bad_json"},
		{"?after=garbage", http.StatusBadRequest, "bad_cursor"},
		{"?order=desc&before=garbage", http.StatusBadRequest, "bad_cursor"},
	} {
		if code, p := get(base + c.q); code != c.code || p.Error != c.token {
			t.Errorf("%s: %d %q, want %d %q", c.q, code, p.Error, c.code, c.token)
		}
	}
	for _, path := range []string{"/v1/view/topics/not-a-uuid", "/v1/view/topics/" + uuidV4()} {
		if code, p := get(path); code != http.StatusNotFound || p.Error != "not_found" {
			t.Errorf("%s: %d %q, want 404 not_found", path, code, p.Error)
		}
	}
	// HUM-2 is not in #live-proof: its topic reads as absent (never 403)
	if code, _, _ := viewGet(t, r.e, r.tid, "/v1/view/topics/"+r.priv, memberHeader, "HUM-2"); code != http.StatusNotFound {
		t.Errorf("outsider: %d", code)
	}
	for _, order := range []struct{ q, cur string }{{"asc", "after"}, {"desc", "before"}} {
		_, all := get(base + "?order=" + order.q)
		var want, walked []string
		for _, m := range all.Messages {
			want = append(want, m.MsgID)
		}
		q := "?order=" + order.q + "&limit=1"
		for n := 0; n < 10; n++ {
			code, p := get(base + q)
			if code != http.StatusOK {
				t.Fatalf("%s page %d: %d %q", order.q, n, code, p.Error)
			}
			for _, m := range p.Messages {
				walked = append(walked, m.MsgID)
			}
			if p.Next == nil {
				break
			}
			q = "?order=" + order.q + "&limit=1&" + order.cur + "=" + url.QueryEscape(*p.Next)
		}
		if len(want) != 3 || !reflect.DeepEqual(walked, want) {
			t.Errorf("%s: walked %v, want %v", order.q, walked, want)
		}
	}
}
