package store

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

// SPL-1729 on memory and, with SPOOL_TEST_PG_DSN, Postgres: when the last
// open issue under an epic closes, the epic closes by itself (done when any
// issue is done, diss when every one was dismissed) through SPL-1643's
// cascade, so it is archived with its issues. Controls: an issue left open
// anywhere under the epic, an epic with no issues, an epic already closed,
// and the reverse path (closing the epic closes its issues inside the store)
// never loops back into an auto-close.
func TestEpicAutoClose(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Second)
			is := s.(Issues)
			tn := uid("ea-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			mk := func(title, kind string, parent int, status string) Issue {
				t.Helper()
				i, err := is.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: tn, Title: title, Kind: kind, Parent: parent, Status: status,
					TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
				if err != nil {
					t.Fatalf("%s: %v", title, err)
				}
				return i
			}
			upd := func(n int, p IssuePatch) Issue {
				t.Helper()
				out, err := is.UpdateIssue(ctx, tn, n, p, "HUM-2", now.Add(time.Minute))
				if err != nil {
					t.Fatalf("update %d: %v", n, err)
				}
				return out
			}
			st := func(n int, status string) Issue { t.Helper(); return upd(n, IssuePatch{Status: &status}) }
			live := func(n int) bool {
				_, err := is.GetIssue(ctx, tn, n)
				if err != nil && !errors.Is(err, ErrNotFound) {
					t.Fatal(err)
				}
				return err == nil
			}

			e := mk("epic", IssueKindEpic, 0, IssueWIP)
			a := mk("issue", "", e.Number, IssueWIP)
			a1 := mk("subtask", "", a.Number, IssueTodo)
			b := mk("dismissed issue", "", e.Number, IssueDiss)

			// An open subtask keeps the epic open.
			if out := st(a.Number, IssueDone); out.AutoClosedEpic != nil || !live(e.Number) {
				t.Fatalf("subtask still open: %+v", out.AutoClosedEpic)
			}
			out := st(a1.Number, IssueDone)
			ep := out.AutoClosedEpic
			if ep == nil || ep.Number != e.Number || ep.Status != IssueDone || ep.CompletedAt == nil ||
				!ep.ClosedArchived || ep.CascadeErr != "" || ep.ClosedWith != nil ||
				!reflect.DeepEqual(ep.ArchivedWith, []int{a.Number, a1.Number, b.Number}) {
				t.Fatalf("auto close: %+v", ep)
			}
			if IsEpicClose(out) {
				t.Fatalf("the subtask's own answer carries a cascade: %+v", out)
			}
			for _, n := range []int{e.Number, a.Number, a1.Number, b.Number} {
				if live(n) {
					t.Fatalf("%d still live", n)
				}
			}

			// Every issue dismissed: the epic is dismissed.
			f := mk("feature", IssueKindFeature, 0, IssueEval)
			g := mk("g", "", f.Number, IssueTodo)
			if ep := st(g.Number, IssueDiss).AutoClosedEpic; ep == nil || ep.Status != IssueDiss || ep.CanceledAt == nil || ep.CompletedAt != nil {
				t.Fatalf("diss: %+v", ep)
			}

			// A closed row moved under an epic whose other issue is closed.
			h := mk("epic h", IssueKindEpic, 0, IssueWIP)
			hi := mk("h issue", "", h.Number, IssueWIP)
			x := mk("plain", "", 0, IssueDone)
			if out := st(hi.Number, IssueDone); out.AutoClosedEpic == nil {
				t.Fatal("h: no auto close")
			}
			h2 := mk("epic h2", IssueKindEpic, 0, IssueWIP)
			mk("h2 issue", "", h2.Number, IssueDone)
			hp := h2.Number
			if out := upd(x.Number, IssuePatch{Parent: &hp}); out.AutoClosedEpic == nil || out.AutoClosedEpic.Number != h2.Number {
				t.Fatalf("move closed row: %+v", out.AutoClosedEpic)
			}

			// No issues: the epic never closes by itself.
			if _, ok := EpicAutoStatus(0, 0, 0); ok {
				t.Fatal("empty epic closes")
			}
			z := mk("empty epic", IssueKindEpic, 0, IssueWIP)
			y := mk("plain 2", "", 0, IssueWIP)
			if out := st(y.Number, IssueDone); out.AutoClosedEpic != nil || !live(z.Number) {
				t.Fatalf("a plain issue closed an epic: %+v", out.AutoClosedEpic)
			}

			// The reverse path (SPL-1643) closes the epic's issues inside the
			// store: it answers its own cascade and no auto close, once.
			r := mk("epic r", IssueKindEpic, 0, IssueWIP)
			r1 := mk("r1", "", r.Number, IssueWIP)
			out = st(r.Number, IssueDone)
			if out.AutoClosedEpic != nil || !out.ClosedArchived || !reflect.DeepEqual(out.ClosedWith, []int{r1.Number}) {
				t.Fatalf("reverse path: %+v", out)
			}
			// Restored: the epic stays done; reopening and closing an issue
			// again does not close (or archive) the closed epic a second time.
			if _, _, err := is.UnarchiveIssue(ctx, tn, e.Number, "HUM-3", now.Add(2*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			st(a1.Number, IssueWIP)
			if out := st(a1.Number, IssueDone); out.AutoClosedEpic != nil || !live(e.Number) {
				t.Fatalf("closed epic closed again: %+v", out.AutoClosedEpic)
			}
			if hs, ok := s.(IssueHistories); ok {
				ev, err := hs.IssueHistory(ctx, tn, e.Number)
				if err != nil {
					t.Fatal(err)
				}
				archived := 0
				for _, v := range ev {
					if v.Event == IssueEventArchived {
						archived++
					}
				}
				if archived != 1 {
					t.Fatalf("epic archived %d times: %+v", archived, ev)
				}
			}
		})
	}
}
