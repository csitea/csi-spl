package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// fakeClaudeToken is a fake of the Claude subscription token's shape, built
// at run time so no token-shaped literal sits in the tree (spec 159 L23: a
// fake of the vendor's shape, never a real one).
func fakeClaudeToken(kind string) string {
	return "sk-ant-" + kind + "01-" + strings.Repeat("Zf0_", 22) + "AA"
}

// Spec 159 row T8, leak path L23: a body that holds a Claude subscription
// token is refused 422 vendor_token_in_body at every body write the hub
// takes - a box send (`spool send`, the desk mirror), a box edit, a browser
// send and a browser edit - and nothing of it reaches the store or the hub
// log. The CONTROL: the same bodies with the token's prefix cut (not the
// shape) are stored. Red control: drop vendorTokenRefusal from a path and
// that case stores the fake. Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestVendorTokenInBodyRefused(t *testing.T) {
	buf := &syncBuf{}
	e := followEnv(t, func(o *hub.Options) { o.Log = zerolog.New(buf).Level(zerolog.DebugLevel) })
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	send := func(body string) (action.SendResult, error) {
		return action.SendCtx(ctx, a.cfg, action.SendArgs{From: "CLE-07", To: "HUM-1", ToBox: hub.WUIBox,
			Kind: "note", Body: body, Hub: a.c})
	}
	stored := func(id string) bool {
		ok, err := e.st.HasMessage(ctx, tid, id)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	human := dialMember(t, e, tid, "HUM-1", "HUM-1")

	for _, kind := range []string{"oat", "ort"} {
		fake := fakeClaudeToken(kind)
		body := "the seat printed its sign-in file:\n{\"accessToken\": \"" + fake + "\"}"

		// 1. box send
		r, err := send(body)
		if got := hubToken(err); got != hub.CodeVendorTokenInBody {
			t.Fatalf("%s box send: want %s, got %v", kind, hub.CodeVendorTokenInBody, err)
		}
		if r.MsgID != "" && stored(r.MsgID) {
			t.Fatalf("%s box send: the refused body was stored", kind)
		}

		// 2. box edit of a clean message
		ok, err := send("a clean line")
		if err != nil {
			t.Fatalf("%s clean send: %v", kind, err)
		}
		_, err = action.Edit(ctx, a.cfg, action.EditArgs{MsgID: ok.MsgID, As: "CLE-07", Body: body, Hub: a.c})
		if got := hubToken(err); got != hub.CodeVendorTokenInBody {
			t.Fatalf("%s box edit: want %s, got %v", kind, hub.CodeVendorTokenInBody, err)
		}
		if b := storedBody(t, e, tid, ok.MsgID); b != "a clean line" {
			t.Fatalf("%s box edit: stored body changed to %q", kind, b)
		}

		// 3. browser send
		wsjson.Write(ctx, human, map[string]any{"type": "send", "task_id": lobby, "body": body}) //nolint:errcheck
		if f := readType(t, human, "error"); f["error"] != hub.CodeVendorTokenInBody || f["status"] != float64(http.StatusUnprocessableEntity) {
			t.Fatalf("%s browser send: %v", kind, f)
		}

		// 4. browser edit of its own clean note
		id, _ := postNote(t, human, "clean note")["msg_id"].(string)
		code, out := patchEdit(t, e, tid, id, "HUM-1", map[string]string{"body": body})
		if code != http.StatusUnprocessableEntity || out["error"] != hub.CodeVendorTokenInBody {
			t.Fatalf("%s browser edit: %d %v", kind, code, out)
		}
		if b := storedBody(t, e, tid, id); b != "clean note" {
			t.Fatalf("%s browser edit: stored body changed to %q", kind, b)
		}

		if buf.contains(fake) || buf.contains(fake[len(fake)-20:]) {
			t.Fatalf("%s: the hub log holds the fake token", kind)
		}
	}

	// CONTROL: not the shape (no sk-ant-oat01- prefix, or too short) -> stored.
	for _, body := range []string{
		"tokens are sk-ant-oat01-<redacted:claude-oauth-token> now",
		"ant-oat01-" + strings.Repeat("Zf0_", 22),
		"sk-ant-oat01-short",
	} {
		r, err := send(body)
		if err != nil || !stored(r.MsgID) {
			t.Fatalf("control %q: want stored, got %v", body, err)
		}
	}
}
