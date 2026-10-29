package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of POST /v1/messages/{id}/merge that no other test drove, taken before
// handleMergeMessage was split and its re-envelope shared with the edit path
// (SPL-1029 round 2).

// A kept message this hub signed is re-signed over the merged body: the new
// envelope verifies against the box-wui key, and the old signature no longer
// covers it.
func TestMergeSignedKeepIsResigned(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e := dispatchEnv(t, false, priv)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Second)
	keepEnv := insertSignedNote(t, e, tid, priv, "22222222-3333-4444-8555-666666666661", "older signed", now.Add(-time.Minute))
	insertSignedNote(t, e, tid, priv, "22222222-3333-4444-8555-666666666662", "newer signed", now)

	code, out := merge(t, e, tid, "22222222-3333-4444-8555-666666666662", "22222222-3333-4444-8555-666666666661", "HUM-1")
	if code != http.StatusOK || out["merged_from"] != "22222222-3333-4444-8555-666666666662" {
		t.Fatalf("merge of signed notes: %d %v", code, out)
	}
	got := storedEnvelope(t, e, tid, "22222222-3333-4444-8555-666666666661")
	if err := got.Verify(pub); err != nil {
		t.Fatalf("merged envelope does not verify against the box-wui key: %v", err)
	}
	if got.Sig == keepEnv.Sig || got.Channel != "lobby" || got.ParentTaskID != signedParent {
		t.Fatalf("merged envelope: sig kept=%v channel=%q parent=%q", got.Sig == keepEnv.Sig, got.Channel, got.ParentTaskID)
	}
	inner, err := got.Inner()
	if err != nil || inner.Body != "older signed\n\nnewer signed" {
		t.Fatalf("merged inner: %+v %v", inner, err)
	}
}

// signedParent is the parent task of the notes insertSignedNote stores.
const signedParent = "44444444-5555-4666-8777-888888888888"

// insertSignedNote stores one lobby note by HUM-1 as box-wui, signed by priv,
// the way the hub stored it when it held that key.
func insertSignedNote(t *testing.T, e *env, tid string, priv ed25519.PrivateKey, id, body string, at time.Time) *wire.Envelope {
	t.Helper()
	m := &msg.Message{V: 1, MsgID: id, TaskID: lobby, TS: at.Format(time.RFC3339), From: "HUM-1", To: "ALL-0",
		Kind: "note", Body: body, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(priv, hub.WUIBox, hub.WUIBox, "lobby", signedParent, m)
	if err != nil {
		t.Fatal(err)
	}
	insertEnvelope(t, e, tid, m, env, "lobby", signedParent, at)
	return env
}

// A kept row another box wrote is that box's to edit: 409 not_editable, both
// rows stay and the kept body is unchanged (SPL-4274, gap E).
func TestMergeKeepFromOtherBoxRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Second)
	mine, _ := postNote(t, dialMember(t, e, tid, "HUM-1", "HUM-1"), "mine")["msg_id"].(string)
	bot := putCard(t, e, tid, lobby, "", "HUM-1", "box-a", 0, now)
	if code, out := merge(t, e, tid, mine, bot, "HUM-1"); code != http.StatusConflict || out["error"] != "not_editable" {
		t.Fatalf("keep from box-a: %d %v, want 409 not_editable", code, out)
	}
	if !has(t, e, tid, mine) || storedBody(t, e, tid, bot) != "hello "+bot {
		t.Fatal("a refused merge changed the rows")
	}
}

// A signed kept row on a hub with no box-wui key cannot be re-signed: 409
// not_editable, the kept body unchanged (SPL-4274, gap F).
func TestMergeSignedKeepWithoutKeyRefused(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Second)
	keep, src := "22222222-3333-4444-8555-666666666671", "22222222-3333-4444-8555-666666666672"
	insertSignedNote(t, e, tid, priv, keep, "older signed", now.Add(-time.Minute))
	insertSignedNote(t, e, tid, priv, src, "newer signed", now)
	if code, out := merge(t, e, tid, src, keep, "HUM-1"); code != http.StatusConflict || out["error"] != "not_editable" {
		t.Fatalf("signed keep, no key: %d %v, want 409 not_editable", code, out)
	}
	if !has(t, e, tid, src) || storedBody(t, e, tid, keep) != "older signed" {
		t.Fatal("a refused merge changed the rows")
	}
}

// An unsigned kept row stays unsigned on a hub that holds the box-wui key:
// the merge never signs a row the hub did not sign (SPL-4274, gap H).
func TestMergeUnsignedKeepStaysUnsigned(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	e := dispatchEnv(t, false, priv)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	keep, _ := postNote(t, author, "first")["msg_id"].(string)
	src, _ := postNote(t, author, "second")["msg_id"].(string)
	if sig := storedEnvelope(t, e, tid, keep).Sig; sig != "" {
		t.Fatalf("precondition: the posted note is signed %q", sig)
	}
	if code, out := merge(t, e, tid, src, keep, "HUM-1"); code != http.StatusOK {
		t.Fatalf("merge of unsigned notes: %d %v", code, out)
	}
	if sig := storedEnvelope(t, e, tid, keep).Sig; sig != "" {
		t.Fatalf("the merge signed an unsigned row: %q", sig)
	}
}

func TestMergeRequestRefusals(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	a, _ := postNote(t, author, strings.Repeat("a", 40000))["msg_id"].(string)
	b, _ := postNote(t, author, strings.Repeat("b", 40000))["msg_id"].(string)
	for _, c := range []struct {
		name, path string
		body       any
		code       int
		token      string
	}{
		{"source not a UUID", "/v1/messages/nope/merge", map[string]string{"into": a}, http.StatusBadRequest, "bad_json"},
		{"unknown field", "/v1/messages/" + b + "/merge", map[string]any{"into": a, "x": 1}, http.StatusBadRequest, "bad_json"},
		{"into not a UUID", "/v1/messages/" + b + "/merge", map[string]string{"into": "nope"}, http.StatusBadRequest, "bad_json"},
		{"into itself", "/v1/messages/" + b + "/merge", map[string]string{"into": strings.ToUpper(b)}, http.StatusBadRequest, "bad_json"},
		{"merged too large", "/v1/messages/" + b + "/merge", map[string]string{"into": a}, http.StatusRequestEntityTooLarge, "too_large"},
	} {
		code, out := call(t, e, tid, http.MethodPost, c.path, "HUM-1", c.body)
		if code != c.code || out["error"] != c.token {
			t.Errorf("%s: %d %v, want %d %s", c.name, code, out, c.code, c.token)
		}
	}
	if err := e.st.SetBillingStatus(context.Background(), tid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	if code, out := merge(t, e, tid, b, a, "HUM-1"); code != billing.HTTPUnpaid || out["error"] != billing.TokenUnpaid {
		t.Errorf("unpaid: %d %v", code, out)
	}
	if !has(t, e, tid, b) || storedBody(t, e, tid, a) != strings.Repeat("a", 40000) {
		t.Fatal("a refused merge changed the rows")
	}
}
