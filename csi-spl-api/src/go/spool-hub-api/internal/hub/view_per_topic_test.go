package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// GET /v1/view/topics?per_topic=N inlines each listed topic's
// newest N messages. The ORACLE is the read the WUI made per topic before:
// every topic's `messages` and `messages_next` must be byte-identical to
// GET /v1/view/topics/{task_id}?order=desc&limit=N's `messages` and `next`,
// through the same session door. Runs on the memory store (the per-topic
// fallback) and, with SPOOL_TEST_PG_DSN, on the Postgres batch read.
func TestViewTopicsPerTopicMatchesTopicReads(t *testing.T) {
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

	// Topics of 1, 3, 5 and 7 messages in #feedback, one reaction.
	var reacted string
	for n := 1; n <= 7; n += 2 {
		task := uuid4()
		for i := 0; i < n; i++ {
			a := channelFrame(t, c, uuid4(), task, "feedback", fmt.Sprintf("topic %d line %d", n, i))
			if reacted == "" {
				reacted, _ = a["msg_id"].(string)
			}
			time.Sleep(2 * time.Millisecond) // distinct received_at
		}
	}
	if err := r.e.st.(store.MessageReactions).AddReaction(ctx, tenant, reacted, me, "👍", time.Now()); err != nil {
		t.Fatal(err)
	}

	get := func(path string) (int, []byte) {
		code, _, body := r.get(t, tenant, path)
		return code, []byte(body)
	}
	for _, per := range []int{1, 3, 5, 50} {
		code, body := get(fmt.Sprintf("/v1/view/topics?channel=feedback&limit=20&per_topic=%d", per))
		if code != http.StatusOK {
			t.Fatalf("per_topic=%d: %d %s", per, code, body)
		}
		var list struct {
			Topics []struct {
				TaskID       string          `json:"task_id"`
				Messages     json.RawMessage `json:"messages"`
				MessagesNext json.RawMessage `json:"messages_next"`
			} `json:"topics"`
		}
		if err := json.Unmarshal(body, &list); err != nil {
			t.Fatal(err)
		}
		if len(list.Topics) != 4 {
			t.Fatalf("per_topic=%d: %d topics, want 4: %s", per, len(list.Topics), body)
		}
		for _, tp := range list.Topics {
			code, one := get(fmt.Sprintf("/v1/view/topics/%s?order=desc&limit=%d", tp.TaskID, per))
			if code != http.StatusOK {
				t.Fatalf("oracle %s: %d %s", tp.TaskID, code, one)
			}
			var want struct {
				Messages json.RawMessage `json:"messages"`
				Next     json.RawMessage `json:"next"`
			}
			if err := json.Unmarshal(one, &want); err != nil {
				t.Fatal(err)
			}
			next := tp.MessagesNext
			if next == nil {
				next = json.RawMessage("null")
			}
			if !bytes.Equal(tp.Messages, want.Messages) || !bytes.Equal(next, want.Next) {
				t.Fatalf("per_topic=%d topic %s differs from its own read:\n inline %s next %s\n oracle %s next %s",
					per, tp.TaskID, tp.Messages, next, want.Messages, want.Next)
			}
		}
	}
	if !bytes.Contains(func() []byte { _, b := get("/v1/view/topics?channel=feedback&per_topic=50"); return b }(), []byte(`"emoji":"👍"`)) {
		t.Fatal("the reaction is not inlined")
	}

	// CONTROL: without per_topic the list is the §4.3 shape, unchanged.
	if _, b := get("/v1/view/topics?channel=feedback"); bytes.Contains(b, []byte(`"messages"`)) {
		t.Fatalf("messages without per_topic: %s", b)
	}
	// CONTROL: out-of-range values are refused, not clamped.
	for _, v := range []string{"0", "51", "-1", "x"} {
		if code, b := get("/v1/view/topics?channel=feedback&per_topic=" + v); code != http.StatusBadRequest {
			t.Fatalf("per_topic=%s: %d %s", v, code, b)
		}
	}
}
