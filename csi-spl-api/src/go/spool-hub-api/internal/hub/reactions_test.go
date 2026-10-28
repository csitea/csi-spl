package hub_test

import (
	"context"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// An emoji can be added to an opening message (is_parent 1) and to a reply
// (is_parent 0). Both come back on the topic read, and the other session is
// told without refetching.

func putReaction(t *testing.T, e *env, tid, msgID, as, emoji string) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/messages/"+msgID+"/reactions", as, map[string]string{"emoji": emoji})
}

func delReaction(t *testing.T, e *env, tid, msgID, as, emoji string) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodDelete, "/v1/messages/"+msgID+"/reactions", as, map[string]string{"emoji": emoji})
}

func reactionActors(t *testing.T, body map[string]any, emoji string) []string {
	t.Helper()
	raw, _ := body["reactions"].([]any)
	for _, item := range raw {
		row, _ := item.(map[string]any)
		if row["emoji"] != emoji {
			continue
		}
		actors, _ := row["actors"].([]any)
		out := make([]string, len(actors))
		for i, a := range actors {
			out[i], _ = a.(string)
		}
		return out
	}
	return nil
}

func rowByBody(t *testing.T, topic map[string]any, body string) map[string]any {
	t.Helper()
	rows, _ := topic["messages"].([]any)
	for _, item := range rows {
		row, _ := item.(map[string]any)
		if bodyOfEnv(t, row) == body {
			return row
		}
	}
	t.Fatalf("no row with body %q in %d messages", body, len(rows))
	return nil
}

func TestReactionOnOpeningAndReply(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	other := dialMember(t, e, tid, "HUM-2", "HUM-2")
	for _, c := range []*websocket.Conn{author, other} {
		wsjson.Write(context.Background(), c, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
		readType(t, c, "subscribed")
	}

	ack1 := postNote(t, author, "opening line")
	id1, _ := ack1["msg_id"].(string)
	readType(t, other, "message")

	wsjson.Write(context.Background(), author, map[string]any{ //nolint:errcheck
		"type": "send", "task_id": lobby, "body": "a reply", "is_parent": 0,
	})
	ack2 := readType(t, author, "ack")
	id2, _ := ack2["msg_id"].(string)
	if id2 == "" || id2 == id1 {
		t.Fatalf("reply id %q", id2)
	}
	readType(t, other, "message")

	// The other person adds an emoji to the opening message (is_parent 1).
	code, out := putReaction(t, e, tid, id1, "HUM-2", "👍")
	if code != http.StatusOK {
		t.Fatalf("add on opening: %d %v", code, out)
	}
	if got := reactionActors(t, out, "👍"); len(got) != 1 || got[0] != "HUM-2" {
		t.Fatalf("opening actors %v", got)
	}
	if f := readType(t, author, "message_reaction"); f["msg_id"] != id1 {
		t.Fatalf("author frame %v", f)
	}
	if f := readType(t, other, "message_reaction"); f["msg_id"] != id1 {
		t.Fatalf("other frame %v", f)
	}

	// The author adds one to the reply (is_parent 0). A second person joins it.
	code, out = putReaction(t, e, tid, id2, "HUM-1", "🎉")
	if code != http.StatusOK {
		t.Fatalf("add on reply: %d %v", code, out)
	}
	readType(t, author, "message_reaction")
	readType(t, other, "message_reaction")
	code, out = putReaction(t, e, tid, id2, "HUM-2", "🎉")
	if code != http.StatusOK {
		t.Fatalf("second add: %d %v", code, out)
	}
	if got := reactionActors(t, out, "🎉"); len(got) != 2 || got[0] != "HUM-1" || got[1] != "HUM-2" {
		t.Fatalf("reply actors %v", got)
	}
	readType(t, author, "message_reaction")
	readType(t, other, "message_reaction")

	// Adding the same emoji again does not duplicate the actor.
	code, out = putReaction(t, e, tid, id1, "HUM-2", "👍")
	if code != http.StatusOK {
		t.Fatalf("idempotent add: %d %v", code, out)
	}
	if got := reactionActors(t, out, "👍"); len(got) != 1 {
		t.Fatalf("idempotent actors %v", got)
	}
	readType(t, author, "message_reaction")
	readType(t, other, "message_reaction")

	code, topic := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+lobby, "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("view: %d %v", code, topic)
	}
	opening := rowByBody(t, topic, "opening line")
	reply := rowByBody(t, topic, "a reply")
	if opening["is_parent"].(float64) != 1 {
		t.Fatalf("opening is_parent %v", opening["is_parent"])
	}
	if reply["is_parent"].(float64) != 0 {
		t.Fatalf("reply is_parent %v", reply["is_parent"])
	}
	if got := reactionActors(t, opening, "👍"); len(got) != 1 || got[0] != "HUM-2" {
		t.Fatalf("reloaded opening %v", opening["reactions"])
	}
	if got := reactionActors(t, reply, "🎉"); len(got) != 2 {
		t.Fatalf("reloaded reply %v", reply["reactions"])
	}

	// Removing the opening emoji clears that chip and leaves the reply.
	code, out = delReaction(t, e, tid, id1, "HUM-2", "👍")
	if code != http.StatusOK {
		t.Fatalf("remove: %d %v", code, out)
	}
	if got := reactionActors(t, out, "👍"); got != nil {
		t.Fatalf("removed chip still present %v", out["reactions"])
	}
	readType(t, author, "message_reaction")
	readType(t, other, "message_reaction")

	// SPL-1002: the bare heart and the picker's heart are one chip, stored
	// in the picker's spelling.
	if code, out = putReaction(t, e, tid, id2, "HUM-1", "\u2764"); code != http.StatusOK {
		t.Fatalf("bare heart: %d %v", code, out)
	}
	if code, out = putReaction(t, e, tid, id2, "HUM-2", "\u2764\uFE0F"); code != http.StatusOK {
		t.Fatalf("picker heart: %d %v", code, out)
	}
	if got := reactionActors(t, out, "\u2764\uFE0F"); len(got) != 2 || reactionActors(t, out, "\u2764") != nil {
		t.Fatalf("two spellings of the heart must be one chip: %v", out["reactions"])
	}
	if code, out = delReaction(t, e, tid, id2, "HUM-1", "\u2764"); code != http.StatusOK || len(reactionActors(t, out, "\u2764\uFE0F")) != 1 {
		t.Fatalf("remove bare heart: %d %v", code, out)
	}
	readType(t, author, "message_reaction")
	readType(t, other, "message_reaction")

	// A glyph the picker does not offer is refused, and so is a missing message.
	if code, out = putReaction(t, e, tid, id2, "HUM-1", "hello"); code != http.StatusBadRequest || out["error"] != "bad_emoji" {
		t.Fatalf("bad emoji: %d %v", code, out)
	}
	if code, out = putReaction(t, e, tid, "00000000-0000-4000-8000-000000000099", "HUM-1", "👍"); code != http.StatusNotFound {
		t.Fatalf("missing message: %d %v", code, out)
	}
	if code, out = putReaction(t, e, tid, id2, "", "👍"); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Fatalf("no session: %d %v", code, out)
	}
}

// reactFailStore fails the emoji write or the chips re-read on demand, so
// the store-error answers of an emoji change can be pinned. The mutex keeps
// the test's set and the handler's read race-free.
type reactFailStore struct {
	store.Store
	mu      sync.Mutex
	addErr  error
	listErr error
}

func (s *reactFailStore) set(addErr, listErr error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.addErr, s.listErr = addErr, listErr
}

func (s *reactFailStore) errs() (addErr, listErr error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addErr, s.listErr
}

func (s *reactFailStore) AddReaction(ctx context.Context, tenant, msgID, actor, emoji string, now time.Time) error {
	if err, _ := s.errs(); err != nil {
		return err
	}
	return s.Store.AddReaction(ctx, tenant, msgID, actor, emoji, now)
}

func (s *reactFailStore) ReactionsFor(ctx context.Context, tenant string, msgIDs []string) (map[string][]store.StoredReaction, error) {
	if _, err := s.errs(); err != nil {
		return nil, err
	}
	return s.Store.ReactionsFor(ctx, tenant, msgIDs)
}

// TestReactionStoreErrors pins the store-error answers of an emoji change:
// the message gone between the lookup and the write is a 404, a failed write
// and a failed chips re-read are each a 500 with no frame fanned out.
func TestReactionStoreErrors(t *testing.T) {
	boom := errors.New("store down")
	cases := []struct {
		name            string
		addErr, listErr error
		code            int
		token, detail   string
	}{
		{"gone_before_store_404", store.ErrNotFound, nil, http.StatusNotFound, "not_found", "no such message"},
		{"store_write_fails_500", boom, nil, http.StatusInternalServerError, "internal", "emoji not stored"},
		{"chips_reread_fails_500", nil, boom, http.StatusInternalServerError, "internal", "emoji not stored"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var f *reactFailStore
			e := followEnv(t, func(o *hub.Options) { f = &reactFailStore{Store: o.Store}; o.Store = f })
			tid, _ := e.tenant()
			author := dialMember(t, e, tid, "HUM-1", "HUM-1")
			wsjson.Write(context.Background(), author, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
			readType(t, author, "subscribed")
			id, _ := postNote(t, author, "react to me")["msg_id"].(string)

			f.set(tc.addErr, tc.listErr)
			code, out := putReaction(t, e, tid, id, "HUM-1", "👍")
			if code != tc.code || out["error"] != tc.token || out["detail"] != tc.detail {
				t.Fatalf("want %d %s %q, got %d %v", tc.code, tc.token, tc.detail, code, out)
			}
			// A refused change must stop there: a handler that wrote the error and
			// went on would still fan the chips out (and append a 200 body).
			quiet(t, author, "no message_reaction after a store error")
		})
	}
}
