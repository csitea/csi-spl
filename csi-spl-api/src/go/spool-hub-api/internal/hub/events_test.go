package hub_test

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

// specs/005 events-v1 (CLE-34990): a human's personal event log, through the
// keys rig (SessionID seam), so two humans can be driven in one test.

func (k *keysRig) ev(t *testing.T, who, method, path, body string) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, "http://login"+domain+"/api/v1/auth/events"+path, rd)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if who != "" {
		req.Header.Set(memberHeader, who)
	}
	resp, err := k.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

type eventsPage struct {
	Events []struct {
		ID         int64  `json:"id"`
		Kind       string `json:"kind"`
		ErrorID    string `json:"error_id"`
		At         string `json:"at"`
		ReceivedAt string `json:"received_at"`
		Source     string `json:"source"`
		Status     int    `json:"status"`
		Message    string `json:"message"`
		Route      string `json:"route"`
	} `json:"events"`
	NextBefore int64 `json:"next_before"`
}

func oneEvent(msg string) string {
	b, _ := json.Marshal(map[string]any{
		"error_id": "ERR-CLIENT-20260925-190000-ABCD", "at": "2026-09-25T19:00:00.123Z",
		"source": "api", "method": "GET", "origin": "https://api.example.test", "path": "/v1/view/roster",
		"status": 502, "code": "", "message": msg, "name": "FetchError", "route": "/lobby",
	})
	return string(b)
}

func batch(msgs ...string) string {
	parts := make([]string, len(msgs))
	for i, m := range msgs {
		parts[i] = oneEvent(m)
	}
	return `{"events":[` + strings.Join(parts, ",") + `]}`
}

func TestEvents_AddListOwnOnlyNewestFirst(t *testing.T) {
	k := newKeysRig(t, 0)
	if c, b := k.ev(t, k.alice, "POST", "", batch("first", "second")); c != http.StatusCreated || !strings.Contains(b, `"added":2`) {
		t.Fatalf("add = %d %s", c, b)
	}
	if c, b := k.ev(t, k.bob, "POST", "", batch("bob's")); c != http.StatusCreated {
		t.Fatalf("bob add = %d %s", c, b)
	}
	c, b := k.ev(t, k.alice, "GET", "", "")
	if c != http.StatusOK {
		t.Fatalf("list = %d %s", c, b)
	}
	var p eventsPage
	if err := json.Unmarshal([]byte(b), &p); err != nil {
		t.Fatal(err)
	}
	if len(p.Events) != 2 || p.Events[0].Message != "second" || p.Events[1].Message != "first" {
		t.Fatalf("alice sees %+v", p.Events)
	}
	e := p.Events[0]
	if e.Kind != "error" || e.ErrorID != "ERR-CLIENT-20260925-190000-ABCD" || e.Status != 502 || e.Route != "/lobby" ||
		!strings.HasPrefix(e.At, "2026-09-25T19:00:00.123") || e.ReceivedAt == "" {
		t.Fatalf("row = %+v", e)
	}
	if strings.Contains(b, "bob's") {
		t.Fatal("alice's log carries bob's event")
	}
}

func TestEvents_PagingWithBefore(t *testing.T) {
	k := newKeysRig(t, 0)
	for i := 0; i < 5; i++ {
		if c, b := k.ev(t, k.alice, "POST", "", batch(fmt.Sprintf("m%d", i))); c != http.StatusCreated {
			t.Fatalf("add = %d %s", c, b)
		}
	}
	var p1, p2 eventsPage
	_, b := k.ev(t, k.alice, "GET", "?limit=3", "")
	_ = json.Unmarshal([]byte(b), &p1)
	if len(p1.Events) != 3 || p1.Events[0].Message != "m4" || p1.NextBefore != p1.Events[2].ID {
		t.Fatalf("page1 = %s", b)
	}
	_, b = k.ev(t, k.alice, "GET", fmt.Sprintf("?limit=3&before=%d", p1.NextBefore), "")
	_ = json.Unmarshal([]byte(b), &p2)
	if len(p2.Events) != 2 || p2.Events[0].Message != "m1" || p2.NextBefore != 0 {
		t.Fatalf("page2 = %s", b)
	}
}

func TestEvents_ClearOnlyMine(t *testing.T) {
	k := newKeysRig(t, 0)
	k.ev(t, k.alice, "POST", "", batch("a"))
	k.ev(t, k.bob, "POST", "", batch("b"))
	if c, b := k.ev(t, k.alice, "POST", "/clear", "{}"); c != http.StatusOK || !strings.Contains(b, `"cleared":1`) {
		t.Fatalf("clear = %d %s", c, b)
	}
	if _, b := k.ev(t, k.alice, "GET", "", ""); !strings.Contains(b, `"events":[]`) {
		t.Fatalf("alice after clear = %s", b)
	}
	if _, b := k.ev(t, k.bob, "GET", "", ""); !strings.Contains(b, `"message":"b"`) {
		t.Fatalf("bob after alice's clear = %s", b)
	}
}

func TestEvents_Refusals(t *testing.T) {
	k := newKeysRig(t, 0)
	tooMany := make([]string, 21)
	for i := range tooMany {
		tooMany[i] = "x"
	}
	cases := []struct {
		name, who, method, path, body string
		want                          int
	}{
		{"anonymous list", "", "GET", "", "", http.StatusUnauthorized},
		{"anonymous add", "", "POST", "", batch("x"), http.StatusUnauthorized},
		{"empty batch", k.alice, "POST", "", `{"events":[]}`, http.StatusBadRequest},
		{"batch over 20", k.alice, "POST", "", batch(tooMany...), http.StatusBadRequest},
		{"unknown top field", k.alice, "POST", "", `{"events":[],"body":"x"}`, http.StatusBadRequest},
		{"unknown event field (a body)", k.alice, "POST", "", `{"events":[{"message":"m","body":"secret"}]}`, http.StatusBadRequest},
		{"unknown event field (headers)", k.alice, "POST", "", `{"events":[{"message":"m","headers":{"a":"b"}}]}`, http.StatusBadRequest},
		{"bad error id", k.alice, "POST", "", `{"events":[{"error_id":"ERR-x-me@example.test"}]}`, http.StatusBadRequest},
		{"message over 800", k.alice, "POST", "", `{"events":[{"message":"` + strings.Repeat("m", 801) + `"}]}`, http.StatusBadRequest},
		{"status out of range", k.alice, "POST", "", `{"events":[{"status":1000}]}`, http.StatusBadRequest},
		{"bad at", k.alice, "POST", "", `{"events":[{"at":"yesterday"}]}`, http.StatusBadRequest},
		{"bad limit", k.alice, "GET", "?limit=0", "", http.StatusBadRequest},
		{"bad before", k.alice, "GET", "?before=x", "", http.StatusBadRequest},
		{"clear with a body field", k.alice, "POST", "/clear", `{"all":true}`, http.StatusBadRequest},
	}
	for _, c := range cases {
		if got, b := k.ev(t, c.who, c.method, c.path, c.body); got != c.want {
			t.Errorf("%s: %d %s, want %d", c.name, got, b, c.want)
		}
	}
	// A 800-rune message of multi-byte runes is inside the cap (runes, not bytes).
	if c, b := k.ev(t, k.alice, "POST", "", `{"events":[{"message":"`+strings.Repeat("ä", 800)+`"}]}`); c != http.StatusCreated {
		t.Fatalf("800 runes = %d %s", c, b)
	}
	req, _ := http.NewRequest("POST", "http://login"+domain+"/api/v1/auth/events", strings.NewReader(batch("x")))
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set(memberHeader, k.alice)
	resp, err := k.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("text/plain = %d", resp.StatusCode)
	}
}

func TestEvents_KeepsNewest500(t *testing.T) {
	k := newKeysRig(t, 1000)
	for i := 0; i < 26; i++ { // 26 x 20 = 520 rows
		msgs := make([]string, 20)
		for j := range msgs {
			msgs[j] = fmt.Sprintf("m%03d", i*20+j)
		}
		if c, b := k.ev(t, k.alice, "POST", "", batch(msgs...)); c != http.StatusCreated {
			t.Fatalf("add %d = %d %s", i, c, b)
		}
	}
	total, before := 0, int64(0)
	last := ""
	for {
		q := "?limit=200"
		if before > 0 {
			q += fmt.Sprintf("&before=%d", before)
		}
		_, b := k.ev(t, k.alice, "GET", q, "")
		var p eventsPage
		if err := json.Unmarshal([]byte(b), &p); err != nil {
			t.Fatal(err)
		}
		total += len(p.Events)
		if len(p.Events) > 0 {
			last = p.Events[len(p.Events)-1].Message
		}
		if p.NextBefore == 0 {
			break
		}
		before = p.NextBefore
	}
	if total != 500 || last != "m020" {
		t.Fatalf("kept %d rows, oldest %q; want 500, m020", total, last)
	}
}

func TestEvents_RateLimited(t *testing.T) {
	k2 := newKeysRig(t, 2)
	for i := 0; i < 2; i++ {
		if c, b := k2.ev(t, k2.alice, "POST", "", batch("x")); c != http.StatusCreated {
			t.Fatalf("add %d = %d %s", i, c, b)
		}
	}
	if c, b := k2.ev(t, k2.alice, "POST", "", batch("x")); c != http.StatusTooManyRequests {
		t.Fatalf("third add = %d %s, want 429", c, b)
	}
	// Reads are not limited; another human has their own window.
	if c, _ := k2.ev(t, k2.alice, "GET", "", ""); c != http.StatusOK {
		t.Fatalf("read after 429 = %d", c)
	}
	if c, _ := k2.ev(t, k2.bob, "POST", "", batch("x")); c != http.StatusCreated {
		t.Fatalf("bob = %d", c)
	}
}
