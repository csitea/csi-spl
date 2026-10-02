package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// GET /v1/view/topics?dm=true&dm_counts=true (DB payload cut 1): each DM
// topic carries the reader's per-peer `dm.unread` / `dm.total` and no
// message, against the dm_read=<peer>~<ts>~<id> cursors sent. Seeded with
// known shapes, so the expected counts are written down: own lines never
// new, the box's lines new until the cursor, a topic longer than the
// counted page totals by its row count. The same rules are pinned against
// the WUI by TestDMCountsMatchWUIFixture. Runs on the memory store (the
// ViewTopic fallback) and, with SPOOL_TEST_PG_DSN, on the thin batch read.
func TestViewTopicsDMCounts(t *testing.T) {
	r := newDoorRig(t)
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	w := &wuiClient{t: t, c: c}
	me := w.read("welcome").As

	bx := r.e.box(tenant, "box-a", "CLE-07", "CLE-08")
	r.e.pin(tenant, bx)
	dm := func(task, to string, n int) {
		for i := 0; i < n; i++ {
			wsjson.Write(ctx, c, map[string]any{"type": "send", "task_id": task, "to": to, "to_box": "box-a", //nolint:errcheck
				"body": fmt.Sprintf("to %s line %d", to, i)})
			w.read("ack")
			time.Sleep(2 * time.Millisecond) // distinct received_at
		}
	}
	// CLE-07: one topic of our own 4 lines + 3 box replies on new tasks.
	// CLE-08: one topic of our own 52 lines, longer than the counted page.
	// The rig labels the agent end of a browser DM by the box the row stores
	// (the WUI reads the same label), so totals are summed per agent id.
	dm(uuid4(), "CLE-07", 4)
	dm(uuid4(), "CLE-08", 52)
	for i := 0; i < 3; i++ {
		send(t, bx, "CLE-07", me, "note", fmt.Sprintf("reply %d", i), "box-wui")
		time.Sleep(2 * time.Millisecond)
	}
	time.Sleep(200 * time.Millisecond)

	type counts struct{ Unread, Total map[string]int }
	read := func(q string) (map[string]int, map[string]int) {
		t.Helper()
		code, _, body := r.get(t, tenant, "/v1/view/topics?dm=true&limit=50&dm_counts=true"+q)
		if code != http.StatusOK {
			t.Fatalf("dm_counts%s: %d %s", q, code, body)
		}
		if strings.Contains(body, `"messages"`) {
			t.Fatalf("dm_counts inlined messages: %s", body)
		}
		var list struct {
			Topics []struct {
				DM *counts `json:"dm"`
			} `json:"topics"`
		}
		if err := json.Unmarshal([]byte(body), &list); err != nil {
			t.Fatal(err)
		}
		unread, total := map[string]int{}, map[string]int{}
		for _, tp := range list.Topics {
			if tp.DM == nil {
				t.Fatalf("a topic without dm counts: %s", body)
			}
			for p, n := range tp.DM.Unread {
				unread[p] += n
			}
			for p, n := range tp.DM.Total {
				total[p] += n
			}
		}
		return unread, total
	}
	const p7 = "CLE-07@box-a" // the box replies' end
	byID := func(m map[string]int) map[string]int {
		out := map[string]int{}
		for p, n := range m {
			id, _, _ := strings.Cut(p, "@")
			out[id] += n
		}
		return out
	}
	unread, total := read("")
	if unread[p7] != 3 || len(unread) != 1 {
		t.Errorf("no cursors: unread %v, want %s:3 only (our own lines are never new)", unread, p7)
	}
	if got := byID(total); got["CLE-07"] != 7 || got["CLE-08"] != 52 || len(got) != 2 {
		t.Errorf("no cursors: total %v, want CLE-07:7 (ours and theirs) CLE-08:52 (the row count)", total)
	}

	// The cursor the WUI keeps after reading the middle reply: (received_at, msg_id).
	code, _, body := r.get(t, tenant, "/v1/view/topics?dm=true&peer="+p7+"&limit=50&per_topic=1")
	if code != http.StatusOK {
		t.Fatalf("replies: %d %s", code, body)
	}
	var page struct {
		Topics []struct {
			Messages []struct {
				ReceivedAt string `json:"received_at"`
				Env        struct {
					Msg struct {
						MsgID string `json:"msg_id"`
						From  string `json:"from"`
					} `json:"msg"`
				} `json:"env"`
			} `json:"messages"`
		} `json:"topics"`
	}
	if err := json.Unmarshal([]byte(body), &page); err != nil {
		t.Fatal(err)
	}
	var replies []string // newest first, "<received_at>~<msg_id>"
	for _, tp := range page.Topics {
		if m := tp.Messages[0]; m.Env.Msg.From == "CLE-07" {
			replies = append(replies, m.ReceivedAt+"~"+m.Env.Msg.MsgID)
		}
	}
	if len(replies) != 3 {
		t.Fatalf("want 3 replies, got %v: %s", replies, body)
	}
	unread, total = read("&dm_read=" + url.QueryEscape(p7+"~"+replies[1]))
	if unread[p7] != 1 || len(unread) != 1 || byID(total)["CLE-07"] != 7 {
		t.Errorf("cursor at the middle reply: unread %v total %v, want %s:1 and CLE-07 total 7", unread, total, p7)
	}
	unread, _ = read("&dm_read=" + url.QueryEscape(p7+"~"+replies[0]))
	if unread[p7] != 0 {
		t.Errorf("cursor at the newest reply: unread %v, want none", unread)
	}
	// Same time, another id: the WUI counts it as new, so does the hub.
	at, _, _ := strings.Cut(replies[0], "~")
	unread, _ = read("&dm_read=" + url.QueryEscape(p7+"~"+at+"~not-this-one"))
	if unread[p7] != 1 {
		t.Errorf("same time, other id: unread %v, want %s:1", unread, p7)
	}

	// CONTROL: without dm_counts the rows carry no counts, as before.
	if _, _, b := r.get(t, tenant, "/v1/view/topics?dm=true"); strings.Contains(b, `"dm":`) {
		t.Fatalf("dm counts without dm_counts: %s", b)
	}
	// CONTROL: malformed values are refused.
	for _, q := range []string{"&dm_counts=yes", "&dm_counts=true&dm_read=no-tilde", "&dm_counts=true&dm_read=~2026"} {
		if code, _, b := r.get(t, tenant, "/v1/view/topics?dm=true"+q); code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", q, code, b)
		}
	}
}
