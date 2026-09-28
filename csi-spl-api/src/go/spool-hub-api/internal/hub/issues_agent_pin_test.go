package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of the agent `issue` frame's refusals that no other test drove, taken
// before onIssue was split into one method per op (SPL-1029 round 2): each
// answers its token, and an unpaid tenant refuses every write but still
// answers the reads.
func TestAgentIssueRefusals(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	token := func(in action.IssueArgs) string {
		t.Helper()
		in.As, in.Hub = "CLE-07", a.c
		_, err := action.Issue(ctx, a.cfg, in)
		var he *hubclient.HubError
		if errors.As(err, &he) {
			return he.Token
		}
		if err != nil {
			t.Fatalf("%+v: %v", in, err)
		}
		return ""
	}
	for _, c := range []struct {
		in   action.IssueArgs
		want string
	}{
		{action.IssueArgs{Op: "update", Ref: "nope", Issue: json.RawMessage(`{"status":"wip"}`)}, "not_found"},
		{action.IssueArgs{Op: "update", Ref: "SPL-1"}, "bad_json"},
		{action.IssueArgs{Op: "list", Query: "status=%zz"}, "bad_issue"},
		{action.IssueArgs{Op: "label", Issue: json.RawMessage(`{"name":"x","extra":1}`)}, "bad_json"},
		{action.IssueArgs{Op: "create"}, "bad_json"},
		{action.IssueArgs{Op: "list"}, ""},
	} {
		if got := token(c.in); got != c.want {
			t.Errorf("%s %q: token %q, want %q", c.in.Op, c.in.Ref+c.in.Query, got, c.want)
		}
	}
	if err := e.st.SetBillingStatus(ctx, tid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	for _, op := range []string{"create", "update", "label", "comment"} {
		if got := token(action.IssueArgs{Op: op, Ref: "SPL-1", Issue: json.RawMessage(`{"title":"x"}`), Body: "x"}); got != billing.TokenUnpaid {
			t.Errorf("unpaid %s: token %q", op, got)
		}
	}
	if got := token(action.IssueArgs{Op: "list"}); got != "" {
		t.Errorf("unpaid list: token %q (reads stay open)", got)
	}
}
