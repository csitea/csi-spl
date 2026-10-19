package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-2607 on memory and, with SPOOL_TEST_PG_DSN, Postgres (rdb 0210):
// GetIssueAnyState answers an archived issue with Archived, and AutoClosed
// only on the epic the SPL-1729 auto-close closed. Controls: an epic a
// person closed (the same SPL-1643 archive), the issues archived with
// either, a live issue (both false, GetIssue unchanged), an unarchive and a
// later archive by hand (the mark ends), and a deleted issue (ErrNotFound).
func TestIssueAutoClosedMark(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Second)
			is := s.(Issues)
			tn := uid("ac-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			mk := func(title, kind string, parent int, status string) int {
				t.Helper()
				i, err := is.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: tn, Title: title, Kind: kind, Parent: parent, Status: status,
					TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
				if err != nil {
					t.Fatalf("%s: %v", title, err)
				}
				return i.Number
			}
			st := func(n int, status string) {
				t.Helper()
				if _, err := is.UpdateIssue(ctx, tn, n, IssuePatch{Status: &status}, "HUM-2", now.Add(time.Minute)); err != nil {
					t.Fatalf("update %d: %v", n, err)
				}
			}
			state := func(n int) [2]bool {
				t.Helper()
				i, err := is.GetIssueAnyState(ctx, tn, n)
				if err != nil || i.Number != n {
					t.Fatalf("get any %d: %v %+v", n, err, i)
				}
				return [2]bool{i.Archived, i.AutoClosed}
			}

			auto := mk("auto", IssueKindEpic, 0, IssueWIP)
			autoKid := mk("last open", "", auto, IssueWIP)
			hand := mk("by hand", IssueKindEpic, 0, IssueWIP)
			handKid := mk("left open", "", hand, IssueWIP)

			if state(auto) != [2]bool{false, false} {
				t.Fatalf("CONTROL live epic flagged: %v", state(auto))
			}
			st(autoKid, IssueDone) // SPL-1729: the epic closes by itself
			if got := state(auto); got != [2]bool{true, true} {
				t.Fatalf("auto-closed epic: %v", got)
			}
			if got := state(autoKid); got != [2]bool{true, false} {
				t.Fatalf("its issue: %v", got)
			}
			if _, err := is.GetIssue(ctx, tn, auto); !errors.Is(err, ErrNotFound) {
				t.Fatalf("GetIssue answers an archived epic: %v", err)
			}

			st(hand, IssueDone) // a person closes it: SPL-1643 archives the same way
			if got := state(hand); got != [2]bool{true, false} {
				t.Fatalf("hand-closed epic: %v", got)
			}
			if got := state(handKid); got != [2]bool{true, false} {
				t.Fatalf("hand-closed epic's issue: %v", got)
			}

			if _, _, err := is.UnarchiveIssue(ctx, tn, auto, "HUM-2", now.Add(2*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			if got := state(auto); got != [2]bool{false, false} {
				t.Fatalf("unarchived epic: %v", got)
			}
			if _, _, err := is.ArchiveIssue(ctx, tn, auto, "HUM-2", now.Add(3*time.Minute), true); err != nil {
				t.Fatal(err)
			}
			if got := state(auto); got != [2]bool{true, false} {
				t.Fatalf("archived by hand after an unarchive: %v", got)
			}

			gone := mk("gone", "", 0, IssueTodo)
			if _, err := is.DeleteIssue(ctx, tn, gone, "HUM-2", now); err != nil {
				t.Fatal(err)
			}
			if _, err := is.GetIssueAnyState(ctx, tn, gone); !errors.Is(err, ErrNotFound) {
				t.Fatalf("deleted issue: %v", err)
			}
			if _, err := is.GetIssueAnyState(ctx, tn, 999); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown issue: %v", err)
			}
		})
	}
}

// TestIssueAutoClosedBackfill0210: the migration marks an archived epic
// whose HUB-0 note "Closed as <st> automatically: ..." came with its
// current archive. Controls, all left false: an epic a person closed (no
// such note), one whose auto-close note is older than its current archive
// (unarchived and closed by hand since), a live epic with the note, and
// another tenant's note on the same task id.
func TestIssueAutoClosedBackfill0210(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0210_issue_auto_closed.sql"))
	if err != nil {
		t.Fatal(err)
	}
	a, b := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Second)
	type epic struct {
		number int
		task   string
	}
	mk := func(tenant string, closed bool) epic {
		t.Helper()
		e, err := pg.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: tenant, Title: "epic", Kind: IssueKindEpic,
			TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
		if err != nil {
			t.Fatal(err)
		}
		if closed {
			done := IssueDone
			if _, err := pg.UpdateIssue(ctx, tenant, e.Number, IssuePatch{Status: &done}, "HUM-2", now); err != nil {
				t.Fatal(err)
			}
		}
		return epic{e.Number, e.TaskID}
	}
	note := func(tenant, task, body string, at time.Time) {
		t.Helper()
		m := msgFor(tenant, task, "box-wui", at, at, uuid4())
		m.FromBox, m.FromID, m.Kind, m.Body, m.Channel = "box-wui", "HUB-0", "note", body, ChannelIssues
		if ins, err := pg.InsertMessage(ctx, m); err != nil || !ins {
			t.Fatalf("note: %v %v", ins, err)
		}
	}
	const autoNote = "Closed as done automatically: its last open issue SPL-9 was closed by HUM-2 at 2026-10-19T00:00:00Z."
	auto, hand, stale, live := mk(a, true), mk(a, true), mk(a, true), mk(a, false)
	other := mk(b, true)
	note(a, auto.task, autoNote, now.Add(time.Second))
	note(a, hand.task, "Closed by hand.", now.Add(time.Second))
	note(a, stale.task, autoNote, now.Add(-time.Hour))
	note(a, live.task, autoNote, now.Add(time.Second))
	note(a, other.task, autoNote, now.Add(time.Second)) // tenant a's note, tenant b's task

	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		what, tenant string
		e            epic
		want         bool
	}{
		{"auto-closed epic", a, auto, true},
		{"hand-closed epic", a, hand, false},
		{"note older than the archive", a, stale, false},
		{"live epic", a, live, false},
		{"another tenant's note", b, other, false},
	} {
		var got bool
		if err := pg.queryRowTenant(ctx, c.tenant, `SELECT auto_closed FROM issues WHERE tenant_id = $1 AND number = $2`,
			[]any{c.tenant, c.e.number}, &got); err != nil || got != c.want {
			t.Errorf("%s: auto_closed %v (%v), want %v", c.what, got, err, c.want)
		}
	}
}
