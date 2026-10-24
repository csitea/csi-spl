package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-3203 (owner HUM-10, t1 8f476aa8 msg 64f8633b): a box send whose
// ```poll fence the WUI would show as a code block is refused 422
// poll_not_a_form with pollProblems' reason, and nothing is stored; a form
// (keys of 1-8 characters, the owner's S180 form among them) and a body with
// no fence are stored as before. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
func TestPollNotAFormRefused(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	b := e.box(tid, "box-b", "CLE-08")
	c := e.box(tid, "box-c", "CLE-09")
	e.pin(tid, b)
	e.pin(tid, c)
	s, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(s)
	post := func(body string) (string, error) {
		env := signedIn(t, b, "box-c", "", "", &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(),
			TS: time.Now().UTC().Format(time.RFC3339), From: "CLE-08", To: "CLE-09", Kind: "note",
			Body: body, Files: []msg.Attachment{}})
		m, _ := env.Inner()
		_, err := s.Send(ctx, env)
		return m.MsgID, err
	}
	stored := func(id string) bool {
		ok, err := e.st.HasMessage(ctx, tid, id)
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}
	fence := func(lines ...string) string {
		return "Pick one:\n\n```poll\n" + strings.Join(lines, "\n") + "\n```\n"
	}

	for _, r := range []struct{ name, body, why string }{
		{"no option line", fence("Which deploy path?"), `question "Which deploy path?" has no option line`},
		{"radios and checkboxes mixed", fence("Which?", "(A) one", "[B] two"), "are mixed"},
		{"key of 9 characters", fence("Which?", "(ABCDEFGHI) nine"), "has no option line"},
		{"never closed", "```poll\nWhich?\n(A) one\n", "is never closed"},
	} {
		id, err := post(r.body)
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Status != http.StatusUnprocessableEntity || he.Token != hub.CodePollNotAForm {
			t.Fatalf("%s: want 422 %s, got %v", r.name, hub.CodePollNotAForm, err)
		}
		if !strings.Contains(he.Detail, r.why) {
			t.Fatalf("%s: detail %q does not name %q", r.name, he.Detail, r.why)
		}
		if stored(id) {
			t.Fatalf("%s: a refused post was stored", r.name)
		}
	}

	for _, r := range []struct{ name, body string }{
		{"owner's form, keys of 4", fence("Which plan?", "(S90) Small 90", "(S180) Small 180", "(S365) Small 365",
			"(K90) Kit 90", "(K180) Kit 180", "(K365) Kit 365")},
		{"keys of 8", fence("Which?", "(ABCDEFGH) eight", "(B) bee")},
		{"checkbox form", fence("Which envs?", "[A] dev", "[B] prd")},
		{"no fence", "plain text, (A) and [B] in prose"},
		{"poll quoted inside another fence", "````md\n```poll\nWhich?\n```\n````"},
	} {
		id, err := post(r.body)
		if err != nil {
			t.Fatalf("%s: refused: %v", r.name, err)
		}
		if !stored(id) {
			t.Fatalf("%s: not stored", r.name)
		}
	}
}
