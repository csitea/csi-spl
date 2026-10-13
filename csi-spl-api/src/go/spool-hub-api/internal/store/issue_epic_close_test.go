package store

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// SPL-1643 on memory and, with SPOOL_TEST_PG_DSN, Postgres: closing an epic
// gives its open issues the epic's status and archives the epic and every
// descendant in the same transaction; unarchiving the epic brings them all
// back with their statuses. Controls: closing a plain issue, or another
// epic's, touches nothing else; a forced cascade failure leaves the epic
// closed, unarchived, and its issues open.
func TestEpicCloseArchivesIssues(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Second)
			is := s.(Issues)
			tn := uid("ec-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			mk := func(title, kind string, parent int, status string) Issue {
				t.Helper()
				i, err := is.CreateIssue(ctx, Issue{TenantID: tn, Title: title, Kind: kind, Parent: parent, Status: status,
					TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
				if err != nil {
					t.Fatalf("%s: %v", title, err)
				}
				return i
			}
			upd := func(n int, st string) Issue {
				t.Helper()
				out, err := is.UpdateIssue(ctx, tn, n, IssuePatch{Status: &st}, "HUM-2", now.Add(time.Minute))
				if err != nil {
					t.Fatalf("close %d: %v", n, err)
				}
				return out
			}
			live := func(n int) bool {
				_, err := is.GetIssue(ctx, tn, n)
				if err != nil && !errors.Is(err, ErrNotFound) {
					t.Fatal(err)
				}
				return err == nil
			}
			e := mk("epic", IssueKindEpic, 0, IssueWIP)
			a := mk("open issue", "", e.Number, IssueWIP)
			a1 := mk("open subtask", "", a.Number, IssueTodo)
			b := mk("done issue", "", e.Number, IssueDone)
			f := mk("other epic", IssueKindFeature, 0, IssueWIP)
			g := mk("other epic's issue", "", f.Number, IssueTodo)
			x := mk("plain issue", "", 0, IssueWIP)

			// Control: a plain issue closes alone.
			if out := upd(x.Number, IssueDone); IsEpicClose(out) || !live(x.Number) {
				t.Fatalf("plain issue: %+v", out)
			}
			// Control: a non-closing change of an epic moves nothing.
			if out := upd(e.Number, IssueQAS); IsEpicClose(out) || !live(a.Number) {
				t.Fatalf("epic to qas: %+v", out)
			}

			out := upd(e.Number, IssueDone)
			if !out.ClosedArchived || out.CascadeErr != "" || out.Status != IssueDone ||
				!reflect.DeepEqual(out.ClosedWith, []int{a.Number, a1.Number}) ||
				!reflect.DeepEqual(out.ArchivedWith, []int{a.Number, a1.Number, b.Number}) {
				t.Fatalf("close epic: %+v", out)
			}
			for _, n := range []int{e.Number, a.Number, a1.Number, b.Number} {
				if live(n) {
					t.Fatalf("%d still live", n)
				}
			}
			if !live(f.Number) || !live(g.Number) || !live(x.Number) {
				t.Fatal("the other epic or the plain issue was archived")
			}

			// Unarchive without cascade: an epic still brings its issues back,
			// statuses kept.
			_, kids, err := is.UnarchiveIssue(ctx, tn, e.Number, "HUM-3", now.Add(2*time.Minute), false)
			if err != nil || !reflect.DeepEqual(kids, []int{a.Number, a1.Number, b.Number}) {
				t.Fatalf("unarchive: %v %v", kids, err)
			}
			for _, n := range []int{e.Number, a.Number, a1.Number, b.Number} {
				i, err := is.GetIssue(ctx, tn, n)
				if err != nil || i.Status != IssueDone || i.CompletedAt == nil || i.CanceledAt != nil {
					t.Fatalf("restored %d: %+v %v", n, i, err)
				}
			}

			// diss: the issues are discarded, canceled_at stamped.
			out = upd(f.Number, IssueDiss)
			if !out.ClosedArchived || !reflect.DeepEqual(out.ClosedWith, []int{g.Number}) {
				t.Fatalf("diss epic: %+v", out)
			}
			if _, _, err := is.UnarchiveIssue(ctx, tn, f.Number, "HUM-3", now.Add(3*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			if gi, err := is.GetIssue(ctx, tn, g.Number); err != nil || gi.Status != IssueDiss || gi.CanceledAt == nil || gi.CompletedAt != nil {
				t.Fatalf("diss issue: %+v %v", gi, err)
			}

			// A forced failure: the epic closes, nothing else moves.
			h := mk("failing epic", IssueKindEpic, 0, IssueWIP)
			hi := mk("failing epic's issue", "", h.Number, IssueWIP)
			SetEpicCloseFault(func(tenant string, epic int) error {
				if tenant == tn && epic == h.Number {
					return fmt.Errorf("forced")
				}
				return nil
			})
			t.Cleanup(func() { SetEpicCloseFault(nil) })
			out = upd(h.Number, IssueDone)
			if out.ClosedArchived || out.CascadeErr != "forced" || !reflect.DeepEqual(out.CascadeOpen, []int{hi.Number}) ||
				out.ClosedWith != nil || out.ArchivedWith != nil {
				t.Fatalf("forced failure: %+v", out)
			}
			hh, err := is.GetIssue(ctx, tn, h.Number)
			if err != nil || hh.Status != IssueDone {
				t.Fatalf("failed cascade: the epic did not close: %+v %v", hh, err)
			}
			if hii, err := is.GetIssue(ctx, tn, hi.Number); err != nil || hii.Status != IssueWIP {
				t.Fatalf("failed cascade moved the issue: %+v %v", hii, err)
			}
		})
	}
}
