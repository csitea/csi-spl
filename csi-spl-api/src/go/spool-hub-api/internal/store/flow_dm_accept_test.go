package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Spec 130 FR-007 follow-up (c-254's finding): a DM that carries accepts
// writes the receiving agent ONE `ready` event, whether the line names it as
// a bare id with its box or as <id>@<box>; a plain DM to an agent still
// writes none (its inbox delivers it). Memory and, with SPOOL_TEST_PG_DSN,
// Postgres.
func TestFlowDMAcceptIsReadyForTheAgent(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe := s.(FlowEvents)
			ctx := context.Background()
			at := time.Now().UTC().Add(-time.Hour)
			tid, task := newTenant(t, s), uuid4()
			n := 0
			post := func(from, to, toBox, kind, body, inner string) Message {
				t.Helper()
				n++
				m := msgFor(tid, task, toBox, at.Add(time.Duration(n)*time.Second), at.Add(time.Duration(n)*time.Second), "env-"+uuid4())
				m.FromID, m.ToID, m.Kind, m.Body = from, to, kind, body
				if inner != "" {
					m.Msg = []byte(inner)
				}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			flow := func(member string) (string, FlowCounts) {
				t.Helper()
				p, err := fe.FlowRead(ctx, FlowQuery{Tenant: tid, Member: member, Limit: 50, Now: at.Add(time.Hour)})
				if err != nil {
					t.Fatal(err)
				}
				out := ""
				for _, e := range p.Events {
					out += e.Kind + ":" + e.Body + "|"
				}
				return out, p.Counts
			}

			r1 := post("c-002", "c-009", "box-a", "result", "done one", "")
			r2 := post("c-004", "c-009", "box-a", "result", "done two", "")
			post("c-009", "c-002", "box-a", "result", "ACCEPTED one", fmt.Sprintf(`{"v":1,"accepts":%q}`, r1.MsgID))
			post("c-009", "c-004@box-a", "box-a", "result", "ACCEPTED two", fmt.Sprintf(`{"v":1,"accepts":%q}`, r2.MsgID))
			post("c-009", "c-002", "box-a", "note", "a plain DM", "")

			for member, want := range map[string]string{"c-002@box-a": "ready:ACCEPTED one|", "c-004@box-a": "ready:ACCEPTED two|"} {
				got, c := flow(member)
				if got != want {
					t.Fatalf("%s flow\n got %q\nwant %q", member, got, want)
				}
				if c.Mention != 1 || c.Total != 1 || c.DMs != 1 {
					t.Fatalf("%s counts %+v: want the one ready DM", member, c)
				}
			}
			for _, member := range []string{"c-002", "c-009@box-a", "c-002@box-b"} {
				if got, _ := flow(member); got != "" {
					t.Fatalf("%s got %q, want nothing", member, got)
				}
			}
		})
	}
}
