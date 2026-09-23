package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// specs/032 contracts/message-edit-v1.md: PATCH /v1/messages/{msg_id}, the
// append-only register behind it, and the message_edited frame.
//
// Every refusal here is a CONTROL in the strict sense: it is written so that
// deleting the guard in edit.go turns it red. A guard nobody has watched
// refuse is not a guard.

// patchEdit sends the edit as member `as` and returns status + decoded body.
func patchEdit(t *testing.T, e *env, tid, msgID, as string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(http.MethodPatch, e.url(tid)+"/v1/messages/"+msgID, rd)
	req.Header.Set("Content-Type", "application/json")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("PATCH: %v", err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// postNote sends one lobby note over the browser socket and returns its ack.
func postNote(t *testing.T, c *websocket.Conn, body string) map[string]any {
	t.Helper()
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "task_id": lobby, "body": body}) //nolint:errcheck
	return readType(t, c, "ack")
}

// bodyOfEnv is the v:1 body inside a { env: { msg } } payload (the view
// element shape the WUI normalises).
func bodyOfEnv(t *testing.T, m map[string]any) string {
	t.Helper()
	env, _ := m["env"].(map[string]any)
	inner, _ := env["msg"].(map[string]any)
	s, _ := inner["body"].(string)
	return s
}

// storedBody reads the message straight out of the store: the ground truth a
// refusal has to leave untouched.
func storedBody(t *testing.T, e *env, tid, msgID string) string {
	t.Helper()
	m, err := e.st.GetEditable(context.Background(), tid, msgID, time.Now())
	if err != nil {
		t.Fatalf("GetEditable: %v", err)
	}
	return m.Body
}

func revisions(t *testing.T, e *env, tid, msgID string) []store.MessageRevision {
	t.Helper()
	rs, err := e.st.MessageRevisions(context.Background(), tid, msgID)
	if err != nil {
		t.Fatalf("MessageRevisions: %v", err)
	}
	return rs
}

// TestEditMessageRoundTrip — US1 + US2 + US3 in one pass: the author edits,
// the response carries the new body and the marker, a SECOND open session is
// pushed a message_edited frame without asking for one, a later read of the
// thread still shows the edit, and the register holds BOTH bodies.
func TestEditMessageRoundTrip(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	for _, c := range []*websocket.Conn{author, watcher} {
		wsjson.Write(context.Background(), c, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
		readType(t, c, "subscribed")
	}
	ack := postNote(t, author, "the orignal text")
	id, _ := ack["msg_id"].(string)
	// The hub fans out before it acks, so the author's own echo was already
	// consumed on the way to the ack; only the watcher's is still queued.
	readType(t, watcher, "message")

	code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": "the original text"})
	if code != http.StatusOK {
		t.Fatalf("edit: %d %v", code, out)
	}
	if got := bodyOfEnv(t, out); got != "the original text" {
		t.Fatalf("response body %q", got)
	}
	if out["edited_at"] == nil || out["edited_by"] != "HUM-1" {
		t.Fatalf("marker: edited_at=%v edited_by=%v", out["edited_at"], out["edited_by"])
	}
	if rev, _ := out["revision"].(float64); rev != 2 {
		t.Fatalf("revision %v (want 2 on a first edit)", out["revision"])
	}
	// FR-ED-009: the message did not move. Same cursor, same received_at as
	// the ack that stored it — a typo fix must not reorder a thread.
	if out["cursor"] != ack["cursor"] || out["received_at"] != ack["received_at"] {
		t.Fatalf("the edit moved the message: cursor %v -> %v, received_at %v -> %v",
			ack["cursor"], out["cursor"], ack["received_at"], out["received_at"])
	}

	// US3: the other session is told, without a refetch.
	f := readType(t, watcher, "message_edited")
	if f["msg_id"] != id || f["task_id"] != lobby {
		t.Fatalf("frame ids: %v", f)
	}
	inner, _ := f["envelope"].(map[string]any)
	if inner["body"] != "the original text" {
		t.Fatalf("frame body %v", inner["body"])
	}
	if f["edited_by"] != "HUM-1" || f["edited_at"] == nil {
		t.Fatalf("frame marker: %v", f)
	}
	if f["cursor"] != ack["cursor"] {
		t.Fatalf("frame cursor %v, want the message's own %v", f["cursor"], ack["cursor"])
	}
	// The editor's own other tabs are in the audience too (contract §3).
	if g := readType(t, author, "message_edited"); g["msg_id"] != id {
		t.Fatalf("the editor's own socket: %v", g)
	}

	// A later read shows the edit and the marker (a reload must agree with
	// the live frame).
	code, thread := call(t, e, tid, http.MethodGet, "/v1/view/threads/"+lobby, "HUM-2", nil)
	if code != http.StatusOK {
		t.Fatalf("view thread: %d %v", code, thread)
	}
	rows, _ := thread["messages"].([]any)
	if len(rows) != 1 {
		t.Fatalf("thread rows %d", len(rows))
	}
	row, _ := rows[0].(map[string]any)
	if got := bodyOfEnv(t, row); got != "the original text" {
		t.Fatalf("thread body %q", got)
	}
	if row["edited_by"] != "HUM-1" || row["edited_at"] == nil || row["revision"].(float64) != 2 {
		t.Fatalf("thread marker: %v", row)
	}

	// US2: BOTH bodies survive. This is the owner's hard constraint.
	rs := revisions(t, e, tid, id)
	if len(rs) != 2 {
		t.Fatalf("register has %d revision(s), want 2", len(rs))
	}
	if rs[0].Revision != 1 || rs[0].Body != "the orignal text" || rs[0].EditedBy != "HUM-1" {
		t.Fatalf("revision 1 must be the body as FIRST SENT: %+v", rs[0])
	}
	if rs[1].Revision != 2 || rs[1].Body != "the original text" {
		t.Fatalf("revision 2: %+v", rs[1])
	}
}

// TestEditMessageAppendsEveryTime — FR-ED-002: a second edit adds a row, it
// does not replace one. Three bodies after two edits.
func TestEditMessageAppendsEveryTime(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "one")["msg_id"].(string)

	for i, body := range []string{"two", "three"} {
		code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": body})
		if code != http.StatusOK {
			t.Fatalf("edit %d: %d %v", i, code, out)
		}
		if rev, _ := out["revision"].(float64); int(rev) != i+2 {
			t.Fatalf("edit %d: revision %v, want %d", i, out["revision"], i+2)
		}
	}
	rs := revisions(t, e, tid, id)
	var got []string
	for _, r := range rs {
		got = append(got, r.Body)
	}
	if len(rs) != 3 || got[0] != "one" || got[1] != "two" || got[2] != "three" {
		t.Fatalf("register after two edits: %v (want [one two three])", got)
	}
	if storedBody(t, e, tid, id) != "three" {
		t.Fatalf("current body %q", storedBody(t, e, tid, id))
	}
}

// CONTROL — TestEditMessageNotAuthor: rule 6. Delete the from_id comparison in
// handleEditMessage and this goes red on the status, on the token AND on the
// stored body.
func TestEditMessageNotAuthor(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "mine")["msg_id"].(string)

	code, out := patchEdit(t, e, tid, id, "HUM-2", map[string]string{"body": "yours now"})
	if code != http.StatusForbidden || out["error"] != "not_author" {
		t.Fatalf("another member's edit: %d %v (want 403 not_author)", code, out)
	}
	if got := storedBody(t, e, tid, id); got != "mine" {
		t.Fatalf("the refusal still changed the body: %q", got)
	}
	if rs := revisions(t, e, tid, id); len(rs) != 0 {
		t.Fatalf("a refused edit wrote %d revision(s)", len(rs))
	}
	// CONTROL of the control: the author's own edit of the same message works,
	// so the 403 is about WHO asked and not about the request being malformed.
	if code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": "still mine"}); code != http.StatusOK {
		t.Fatalf("the author's own edit: %d %v", code, out)
	}
}

// CONTROL — TestEditMessageEmptyBody: an empty or whitespace-only body is
// refused. Delete the TrimSpace guard and this goes red. The hub refuses it
// rather than trusting the composer, because the composer's own empty guard
// has been bypassed before (CLE-3433 found a body = "" row in the dev store).
func TestEditMessageEmptyBody(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "real text")["msg_id"].(string)

	for _, body := range []string{"", "   ", "\n\t "} {
		code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": body})
		if code != http.StatusBadRequest || out["error"] != "empty_body" {
			t.Fatalf("body %q: %d %v (want 400 empty_body)", body, code, out)
		}
		if got := storedBody(t, e, tid, id); got != "real text" {
			t.Fatalf("body %q: the refusal still changed the message to %q", body, got)
		}
	}
	// A body missing from the JSON altogether is the same refusal.
	if code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{}); code != http.StatusBadRequest || out["error"] != "empty_body" {
		t.Fatalf("no body key: %d %v", code, out)
	}
}

// CONTROL — TestEditMessageNotEditable: rule 7 for a from_box other than
// box-wui, on a hub that also has no box-wui key. Delete the whole refusal
// and this goes red. The keyed twin (TestEditMessageOtherBoxWithKey) is what
// goes red when only the FromBox half is deleted: a hub that holds a key
// must still refuse a box it cannot re-sign for. Rewriting the body under
// that box's signature would leave an envelope that no longer verifies
// against its own pin.
func TestEditMessageNotEditable(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	// A message from a real box, authored by HUM-1, stored as the box path
	// stores it: a non-empty sig and a from_box that is not box-wui.
	now := time.Now().UTC().Truncate(time.Microsecond)
	m := &msg.Message{V: 1, MsgID: "11111111-2222-4333-8444-555555555555", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "HUM-1", To: "ALL-0", Kind: "note",
		Body: "signed by a box", Files: []msg.Attachment{}}
	inner, err := msg.Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	env := &wire.Envelope{FromBox: "box-a", ToBox: hub.WUIBox, Msg: inner, Sig: "not-verified-here"}
	canon, err := env.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	row := store.Message{TenantID: tid, MsgID: m.MsgID, TaskID: m.TaskID, TS: now,
		FromBox: "box-a", FromID: "HUM-1", ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note",
		Body: m.Body, Files: []byte(`[]`), Msg: inner, EnvSig: env.Sig, Env: canon,
		ReceivedAt: now, ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), row); err != nil {
		t.Fatal(err)
	}

	code, out := patchEdit(t, e, tid, m.MsgID, "HUM-1", map[string]string{"body": "rewritten"})
	if code != http.StatusConflict || out["error"] != "not_editable" {
		t.Fatalf("editing a box-signed message: %d %v (want 409 not_editable)", code, out)
	}
	if got := storedBody(t, e, tid, m.MsgID); got != "signed by a box" {
		t.Fatalf("the refusal still changed the body: %q", got)
	}
}

// TestEditMessageNotFound: absent, another tenant's, and a malformed id. All
// three answer the same way, on purpose — the 404 must not be a way to learn
// that a message exists somewhere else.
func TestEditMessageNotFound(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	author := dialMember(t, e, other, "HUM-1", "HUM-1")
	elsewhere, _ := postNote(t, author, "another tenant's")["msg_id"].(string)

	code, out := patchEdit(t, e, tid, "00000000-0000-4000-8000-00000000dead", "HUM-1", map[string]string{"body": "x"})
	if code != http.StatusNotFound || out["error"] != "not_found" {
		t.Fatalf("absent: %d %v", code, out)
	}
	code, out = patchEdit(t, e, tid, elsewhere, "HUM-1", map[string]string{"body": "x"})
	if code != http.StatusNotFound || out["error"] != "not_found" {
		t.Fatalf("another tenant's message: %d %v (want 404, never 403)", code, out)
	}
	if got := storedBody(t, e, other, elsewhere); got != "another tenant's" {
		t.Fatalf("a cross-tenant edit reached the body: %q", got)
	}
	if code, out = patchEdit(t, e, tid, "not-a-uuid", "HUM-1", map[string]string{"body": "x"}); code != http.StatusBadRequest {
		t.Fatalf("malformed id: %d %v", code, out)
	}
}

// TestEditMessageGuestRefused: rule 2. A door-off guest has no stable identity
// and can never be the author of anything.
func TestEditMessageGuestRefused(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "mine")["msg_id"].(string)

	code, out := patchEdit(t, e, tid, id, "", map[string]string{"body": "guest edit"})
	if code != http.StatusForbidden || out["error"] != "forbidden" {
		t.Fatalf("guest edit: %d %v (want 403 forbidden)", code, out)
	}
	if got := storedBody(t, e, tid, id); got != "mine" {
		t.Fatalf("a guest changed the body to %q", got)
	}
}

// TestEditMessagePreflight: the browser's PATCH is cross-origin, so it is
// preflighted. No new request header is introduced — a new header is a new
// preflight, and this repo has broken sign-in that way once.
func TestEditMessagePreflight(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/messages/00000000-0000-4000-8000-000000000001", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "PATCH")
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight: %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != wuiOrigin {
		t.Fatalf("allow-origin %q", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Methods"); got != "PATCH" {
		t.Fatalf("allow-methods %q", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type, X-Locale" {
		t.Fatalf("allow-headers %q", got)
	}
}

// TestEditMessageUnedited: a message nobody edited carries NO marker key at
// all. Absence is the signal the browser tests on, so an accidental
// "edited_at": null would render "(edited)" on every message in the product.
func TestEditMessageUnedited(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	postNote(t, author, "never edited")

	code, thread := call(t, e, tid, http.MethodGet, "/v1/view/threads/"+lobby, "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("view thread: %d %v", code, thread)
	}
	rows, _ := thread["messages"].([]any)
	if len(rows) != 1 {
		t.Fatalf("thread rows %d", len(rows))
	}
	row, _ := rows[0].(map[string]any)
	for _, k := range []string{"edited_at", "edited_by", "revision"} {
		if _, present := row[k]; present {
			t.Fatalf("an unedited message carries %q = %v; the key must be absent", k, row[k])
		}
	}
}

// insertEnvelope stores one message exactly as the box path stored it, so the
// edit tests can name from_box and the signature without going through a send.
func insertEnvelope(t *testing.T, e *env, tid string, m *msg.Message, env *wire.Envelope, channel, parent string, now time.Time) {
	t.Helper()
	canon, err := env.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	row := store.Message{
		TenantID: tid, MsgID: m.MsgID, TaskID: m.TaskID, Channel: channel, ParentTaskID: parent, TS: now,
		FromBox: env.FromBox, FromID: m.From, ToBox: env.ToBox, ToID: m.To, Kind: m.Kind,
		Body: m.Body, Files: []byte(`[]`), Msg: env.Msg, EnvSig: env.Sig, Env: canon,
		ReceivedAt: now, ExpiresAt: now.Add(24 * time.Hour),
	}
	if _, err := e.st.InsertMessage(context.Background(), row); err != nil {
		t.Fatal(err)
	}
}

// storedEnvelope is the envelope the edit actually persisted.
func storedEnvelope(t *testing.T, e *env, tid, msgID string) *wire.Envelope {
	t.Helper()
	got, err := e.st.GetEditable(context.Background(), tid, msgID, time.Now())
	if err != nil {
		t.Fatalf("GetEditable: %v", err)
	}
	env, err := wire.ParseEnvelope(got.Env)
	if err != nil {
		t.Fatal(err)
	}
	return env
}

// CONTROL — TestEditMessageBoxWUIResign: a browser post the hub signed with
// its own box-wui key stays editable by its author, and the stored envelope
// verifies against that same key afterwards. Delete the re-sign (or put the
// old blanket `EnvSig != ""` refusal back) and this goes red: either the
// status is 409, or the new body sits under a signature that does not verify.
func TestEditMessageBoxWUIResign(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e := dispatchEnv(t, false, priv) // key held, dispatch off: a plain lobby note stays unsigned
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Second)
	parent := "44444444-5555-4666-8777-888888888888"

	channelMsg := &msg.Message{V: 1, MsgID: "22222222-3333-4444-8555-666666666666", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "HUM-1", To: "ALL-0", Kind: "note",
		Body: "signed channel post", Files: []msg.Attachment{}}
	channelEnv, err := wire.NewEnvelopeIn(priv, hub.WUIBox, hub.WUIBox, "lobby", parent, channelMsg)
	if err != nil {
		t.Fatal(err)
	}
	if err := channelEnv.Verify(pub); err != nil {
		t.Fatal(err)
	}
	insertEnvelope(t, e, tid, channelMsg, channelEnv, "lobby", parent, now)

	// Rule 6 is unchanged by a signature the hub could re-sign. Another member
	// is 403, not 409, and the body is untouched.
	code, out := patchEdit(t, e, tid, channelMsg.MsgID, "HUM-2", map[string]string{"body": "not yours"})
	if code != http.StatusForbidden || out["error"] != "not_author" {
		t.Fatalf("another member: %d %v (want 403 not_author)", code, out)
	}
	if got := storedBody(t, e, tid, channelMsg.MsgID); got != "signed channel post" {
		t.Fatalf("the refusal changed the body: %q", got)
	}

	code, out = patchEdit(t, e, tid, channelMsg.MsgID, "HUM-1", map[string]string{"body": "edited channel post"})
	if code != http.StatusOK {
		t.Fatalf("author edit of a hub-signed post: %d %v", code, out)
	}
	if got := bodyOfEnv(t, out); got != "edited channel post" {
		t.Fatalf("response body %q", got)
	}
	edited := storedEnvelope(t, e, tid, channelMsg.MsgID)
	if err := edited.Verify(pub); err != nil {
		t.Fatalf("edited envelope does not verify against the hub box-wui key: %v", err)
	}
	if edited.Sig == channelEnv.Sig {
		t.Fatal("edit left the original signature on the new body")
	}
	if edited.FromBox != hub.WUIBox || edited.ToBox != hub.WUIBox || edited.Channel != "lobby" || edited.ParentTaskID != parent {
		t.Fatalf("channel envelope tags: %+v", edited)
	}
	inner, err := edited.Inner()
	if err != nil {
		t.Fatal(err)
	}
	if inner.Body != "edited channel post" || inner.From != "HUM-1" || inner.MsgID != channelMsg.MsgID || inner.TS != channelMsg.TS {
		t.Fatalf("inner after edit: %+v", inner)
	}
	// The signature the row was born with must not still cover the new body.
	stale := *edited
	stale.Sig = channelEnv.Sig
	if err := stale.Verify(pub); err == nil {
		t.Fatal("the original signature still verifies the edited envelope")
	}

	// A second edit still verifies. The store keeps the original env_sig, so
	// the column staying non-empty must keep taking the re-sign path.
	code, out = patchEdit(t, e, tid, channelMsg.MsgID, "HUM-1", map[string]string{"body": "edited again"})
	if code != http.StatusOK {
		t.Fatalf("second edit: %d %v", code, out)
	}
	again := storedEnvelope(t, e, tid, channelMsg.MsgID)
	if err := again.Verify(pub); err != nil {
		t.Fatalf("second edit does not verify: %v", err)
	}
	if again.Sig == edited.Sig {
		t.Fatal("second edit reused the previous signature")
	}

	// A dispatch (from box-wui, to a real box) is the same key. Re-signing
	// must keep that to_box: the post is not rewritten into a channel post.
	dispatchMsg := &msg.Message{V: 1, MsgID: "33333333-4444-4555-8666-777777777777", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "HUM-1", To: "CLE-07", Kind: "task",
		Body: "signed dispatch", Files: []msg.Attachment{}}
	dispatchEnvl, err := wire.NewEnvelopeIn(priv, hub.WUIBox, "box-a", "", "", dispatchMsg)
	if err != nil {
		t.Fatal(err)
	}
	insertEnvelope(t, e, tid, dispatchMsg, dispatchEnvl, "", "", now)
	code, out = patchEdit(t, e, tid, dispatchMsg.MsgID, "HUM-1", map[string]string{"body": "edited dispatch"})
	if code != http.StatusOK {
		t.Fatalf("author edit of a hub-signed dispatch: %d %v", code, out)
	}
	gotEnv := storedEnvelope(t, e, tid, dispatchMsg.MsgID)
	if err := gotEnv.Verify(pub); err != nil {
		t.Fatalf("edited dispatch does not verify: %v", err)
	}
	if gotEnv.FromBox != hub.WUIBox || gotEnv.ToBox != "box-a" || gotEnv.Channel != "" || gotEnv.ParentTaskID != "" {
		t.Fatalf("dispatch envelope tags: %+v", gotEnv)
	}

	// An unsigned browser note on the same hub stays editable, and stays
	// unsigned. Signing it here would turn a lobby note into a box envelope.
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	id, _ := postNote(t, author, "lobby note")["msg_id"].(string)
	code, out = patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": "lobby note edited"})
	if code != http.StatusOK {
		t.Fatalf("unsigned note: %d %v", code, out)
	}
	plain := storedEnvelope(t, e, tid, id)
	if plain.Sig != "" {
		t.Fatalf("unsigned edit gained a signature %q", plain.Sig)
	}
	if plain.FromBox != hub.WUIBox {
		t.Fatalf("unsigned from_box %q", plain.FromBox)
	}
	if got := storedBody(t, e, tid, id); got != "lobby note edited" {
		t.Fatalf("unsigned body %q", got)
	}
}

// CONTROL — TestEditMessageSignedNoKey: a signed box-wui envelope on a hub
// that holds no box-wui key stays 409. Delete the `pub == nil` half and this
// either panics in the signer or stores an edit it cannot re-sign.
func TestEditMessageSignedNoKey(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: "55555555-6666-4777-8888-999999999999", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "HUM-1", To: "ALL-0", Kind: "note",
		Body: "signed, hub holds no key", Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(priv, hub.WUIBox, hub.WUIBox, "lobby", "", m)
	if err != nil {
		t.Fatal(err)
	}
	insertEnvelope(t, e, tid, m, env, "lobby", "", now)

	code, out := patchEdit(t, e, tid, m.MsgID, "HUM-1", map[string]string{"body": "rewritten"})
	if code != http.StatusConflict || out["error"] != "not_editable" {
		t.Fatalf("signed envelope, no hub key: %d %v (want 409 not_editable)", code, out)
	}
	if got := storedBody(t, e, tid, m.MsgID); got != "signed, hub holds no key" {
		t.Fatalf("the refusal changed the body: %q", got)
	}
	if got := storedEnvelope(t, e, tid, m.MsgID); got.Sig != env.Sig {
		t.Fatal("the refusal replaced the signature")
	}
}

// CONTROL — TestEditMessageOtherBoxWithKey: holding the box-wui key must not
// make some other box's envelope editable. Delete the FromBox check and this
// goes red, because the hub would re-sign box-a's bytes with its own key.
func TestEditMessageOtherBoxWithKey(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e := dispatchEnv(t, false, priv)
	tid, _ := e.tenant()
	_, boxKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: "66666666-7777-4888-8999-aaaaaaaaaaaa", TaskID: lobby,
		TS: now.Format(time.RFC3339), From: "HUM-1", To: "ALL-0", Kind: "note",
		Body: "signed by box-a", Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(boxKey, "box-a", hub.WUIBox, "", "", m)
	if err != nil {
		t.Fatal(err)
	}
	insertEnvelope(t, e, tid, m, env, "", "", now)

	code, out := patchEdit(t, e, tid, m.MsgID, "HUM-1", map[string]string{"body": "rewritten by the hub"})
	if code != http.StatusConflict || out["error"] != "not_editable" {
		t.Fatalf("other box, hub holds a key: %d %v (want 409 not_editable)", code, out)
	}
	if got := storedBody(t, e, tid, m.MsgID); got != "signed by box-a" {
		t.Fatalf("the refusal changed the body: %q", got)
	}
	if got := storedEnvelope(t, e, tid, m.MsgID); got.Sig != env.Sig || got.FromBox != "box-a" {
		t.Fatalf("the refusal rewrote the envelope: %+v", got)
	}
}
