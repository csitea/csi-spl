package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/119 T004 (spec 8.1, 8.2, 11 T-R1): the receipt copy. The contract
// runs on Memory and, under hub-pg.tst.sh, on Postgres as the runtime login
// (the workspace seeded by the migrate login). The route half (T-R2, T-R9,
// T-R10) is hub/rbac_test.go's.

// The copy's two weeks: A (2026-09-07..13) approved by Q, B (2026-09-14..20)
// still open when P leaves on Wednesday 2026-09-16.
var (
	receiptWeekA = time.Date(2026, 9, 8, 10, 0, 0, 0, time.UTC)
	receiptLeave = time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)
	receiptDecAt = time.Date(2026, 9, 15, 8, 0, 0, 0, time.UTC)
)

// The content a receipt must never carry: an entry note and a target id.
const (
	receiptNote  = "note-secret-payroll-dispute"
	receiptTopic = "t:topic-secret-title"
)

// copyFix is one driver: the store that copies and reads, the store that
// seeds the workspace, how to seed a human, and how to read receipt_due.
type copyFix struct {
	copier  RealmReceiptCopier
	realm   Realm
	seed    Store
	human   func(t *testing.T, person, name string)
	dueOf   func(t *testing.T, person, ws string) (RealmReceiptDue, bool)
	removed func(t *testing.T, ws, person string)
}

func memCopyFix() copyFix {
	m := NewMemory()
	return copyFix{copier: m, realm: m, seed: m,
		human: func(_ *testing.T, person, name string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hum.init()
			m.hum.humans[person] = &memHuman{name: name}
		},
		dueOf: func(_ *testing.T, person, ws string) (RealmReceiptDue, bool) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.realm.init()
			d, ok := m.realm.due[person][ws]
			return d, ok
		},
	}
}

func pgCopyFix(t *testing.T) copyFix {
	rf, pg, rt := pgRealmFix(t)
	ctx := context.Background()
	return copyFix{copier: rt, realm: rt, seed: pg,
		human: func(t *testing.T, person, name string) {
			rf.addHuman(t, person)
			if _, err := pg.pool.Exec(ctx, `UPDATE humans SET display_name = $2 WHERE human_id = $1`, person, name); err != nil {
				t.Fatal(err)
			}
		},
		dueOf: func(t *testing.T, person, ws string) (RealmReceiptDue, bool) {
			var d RealmReceiptDue
			found := false
			err := rt.inPerson(ctx, person, func(tx pgx.Tx) error {
				err := tx.QueryRow(ctx, `SELECT reason, COALESCE(last_open_from::text, ''), due_at, done_at
					FROM personal.receipt_due WHERE person_id = $1 AND workspace_id = $2`, person, ws).
					Scan(&d.Reason, &d.LastOpenFrom, &d.DueAt, &d.DoneAt)
				if errors.Is(err, pgx.ErrNoRows) {
					return nil
				}
				found = err == nil
				return err
			})
			if err != nil {
				t.Fatal(err)
			}
			return d, found
		},
	}
}

func copyDrivers(t *testing.T) map[string]func(*testing.T) copyFix {
	return map[string]func(*testing.T) copyFix{
		"memory":   func(*testing.T) copyFix { return memCopyFix() },
		"postgres": pgCopyFix,
	}
}

// seedReceiptHours gives person in ws week A (approved by approver) and, when
// open is set, a day of week B (no period row yet).
func seedReceiptHours(t *testing.T, st Store, ws, person, approver string, open bool) {
	t.Helper()
	ctx := context.Background()
	h := hoursStore(t, st)
	e := func(day, target string, minutes int, state, note string) HoursEntry {
		return HoursEntry{Day: day, Target: target, Minutes: minutes, State: state, Note: note}
	}
	if err := h.PutHoursEntries(ctx, ws, person, []HoursEntry{
		e("2026-09-08", receiptTopic, 120, HoursApproved, receiptNote),
		e("2026-09-08", "t:another-topic", 60, HoursApproved, ""),
		e("2026-09-08", "ch:lobby", 30, HoursApproved, ""),
		e("2026-09-09", "dm:HUM-5", 15, HoursApproved, ""),
		e("2026-09-09", "ws", 45, HoursRejected, ""),
	}, person, receiptWeekA); err != nil {
		t.Fatal(err)
	}
	p := HoursPeriod{Member: person, Start: "2026-09-07", End: "2026-09-13", State: HoursFrozen, Minutes: 225,
		DecidedBy: "sweep", DecidedAt: receiptWeekA}
	if _, err := h.CreateHoursPeriod(ctx, ws, p); err != nil {
		t.Fatal(err)
	}
	if _, err := h.SetHoursPeriodState(ctx, ws, person, p.Start,
		HoursPeriodChange{State: HoursApproved, By: approver, At: receiptDecAt}); err != nil {
		t.Fatal(err)
	}
	if open {
		if err := h.PutHoursEntries(ctx, ws, person, []HoursEntry{e("2026-09-15", "cal:evt-1", 90, HoursApproved, "")},
			person, receiptLeave); err != nil {
			t.Fatal(err)
		}
	}
}

// showReceipts is the rows of ws, one line each, 8.2's columns.
func showReceipts(rs []RealmReceipt, ws string) []string {
	var out []string
	for _, r := range rs {
		if r.WorkspaceID != ws {
			continue
		}
		at := ""
		if r.DecidedAt != nil {
			at = r.DecidedAt.UTC().Format(time.RFC3339)
		}
		out = append(out, fmt.Sprintf("%s|%s|%s|%d|%s..%s|%s|%s|%s|rev%d", r.Day, r.Label, r.Kind, r.Minutes,
			r.PeriodStart, r.PeriodEnd, r.ApprovalState, r.ApproverName, at, r.Rev))
	}
	return out
}

// TestRealmReceiptCopy is T-R1's store half: one row per (day, label, kind)
// with 8.2's columns, minutes summed, a rejected entry left out, the note
// and the target id nowhere, the workspace's hours untouched, a retry
// writing nothing, and receipt_due open from the first day not final.
// CONTROLS: the content strings are in the workspace (so "nowhere" is
// meaningful), and a fully final workspace closes its receipt_due row.
func TestRealmReceiptCopy(t *testing.T) {
	ctx := context.Background()
	for name, mk := range copyDrivers(t) {
		t.Run(name, func(t *testing.T) {
			f := mk(t)
			p, q := realmPersons()
			f.human(t, p, "FirstName LastName")
			f.human(t, q, "Approver Name")
			ws, final := newTenant(t, f.seed), newTenant(t, f.seed)
			seedReceiptHours(t, f.seed, ws, p, q, true)
			seedReceiptHours(t, f.seed, final, p, q, false)

			n, err := f.copier.CopyRealmReceipts(ctx, ws, p, RealmDueRemoved, receiptLeave)
			if err != nil || n != 4 {
				t.Fatalf("copy: %d %v, want 4 rows", n, err)
			}
			rs, err := f.realm.RealmReceipts(ctx, p)
			if err != nil {
				t.Fatal(err)
			}
			dec := receiptDecAt.Format(time.RFC3339)
			want := []string{
				"2026-09-08|channel|work|30|2026-09-07..2026-09-13|approved|Approver Name|" + dec + "|rev0",
				"2026-09-08|topic|work|180|2026-09-07..2026-09-13|approved|Approver Name|" + dec + "|rev0",
				"2026-09-09|direct message|work|15|2026-09-07..2026-09-13|approved|Approver Name|" + dec + "|rev0",
				"2026-09-15|meeting|work|90|2026-09-14..2026-09-20|open|||rev0",
			}
			if got := showReceipts(rs, ws); strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("receipts:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			for _, r := range rs {
				all := fmt.Sprintf("%+v", r)
				if strings.Contains(all, "secret") || strings.Contains(all, "lobby") || strings.Contains(all, "evt-1") {
					t.Fatalf("content in a receipt: %s", all)
				}
				if r.WorkspaceName != ws {
					t.Fatalf("workspace name %q, want the id %q (no display name set)", r.WorkspaceName, ws)
				}
			}
			kept, err := hoursStore(t, f.seed).HoursEntries(ctx, ws, p, realmCopyFrom, realmCopyTo)
			if err != nil || len(kept) != 6 {
				t.Fatalf("the workspace keeps P's hours: %d %v, want 6", len(kept), err)
			}
			if !strings.Contains(fmt.Sprintf("%+v", kept), receiptNote) {
				t.Fatal("CONTROL: the seeded note is not in the workspace, so its absence proves nothing")
			}
			if d, ok := f.dueOf(t, p, ws); !ok || d.Reason != RealmDueRemoved || d.LastOpenFrom != "2026-09-15" || d.DoneAt != nil {
				t.Fatalf("receipt_due %+v %v, want removed, open from 2026-09-15", d, ok)
			}

			// A retry is idempotent: nothing written, the rows unchanged.
			if n, err := f.copier.CopyRealmReceipts(ctx, ws, p, RealmDueRemoved, receiptLeave.Add(time.Hour)); err != nil || n != 0 {
				t.Fatalf("retry: %d %v, want 0", n, err)
			}
			if again, _ := f.realm.RealmReceipts(ctx, p); len(showReceipts(again, ws)) != 4 {
				t.Fatalf("retry changed the receipts: %v", showReceipts(again, ws))
			}
			if d, _ := f.dueOf(t, p, ws); d.DoneAt != nil || d.LastOpenFrom != "2026-09-15" {
				t.Fatalf("a retry closed an open receipt_due: %+v", d)
			}

			// CONTROL: every day final, receipt_due is done at once.
			if n, err := f.copier.CopyRealmReceipts(ctx, final, p, RealmDueRemoved, receiptLeave); err != nil || n != 3 {
				t.Fatalf("final copy: %d %v, want 3", n, err)
			}
			if d, ok := f.dueOf(t, p, final); !ok || d.LastOpenFrom != "" || d.DoneAt == nil {
				t.Fatalf("receipt_due of a final workspace %+v %v, want done", d, ok)
			}
			// Q, the approver, got nothing.
			if rq, err := f.realm.RealmReceipts(ctx, q); err != nil || len(rq) != 0 {
				t.Fatalf("Q's receipts %v %v, want none", rq, err)
			}
		})
	}
}

// TestRealmReceiptCopyRefuses: every failure is ErrRealmCopy and writes
// nothing (the caller then keeps the membership, 8.1).
func TestRealmReceiptCopyRefuses(t *testing.T) {
	ctx := context.Background()
	for name, mk := range copyDrivers(t) {
		t.Run(name, func(t *testing.T) {
			f := mk(t)
			p, ghost := realmPersons()
			f.human(t, p, "FirstName LastName")
			ws := newTenant(t, f.seed)
			seedReceiptHours(t, f.seed, ws, ghost, p, false) // hours of a person with no humans row
			for _, c := range []struct{ name, ws, person, reason string }{
				{"no such workspace", "t-nope-" + p, p, RealmDueRemoved},
				{"not a person", ws, "AGT-1", RealmDueRemoved},
				{"injection", ws, "HUM-1; --", RealmDueRemoved},
				{"unknown reason", ws, p, "disabled"},
				{"no such human (FK)", ws, ghost, RealmDueRemoved},
			} {
				if n, err := f.copier.CopyRealmReceipts(ctx, c.ws, c.person, c.reason, receiptLeave); !errors.Is(err, ErrRealmCopy) || n != 0 {
					t.Errorf("%s: %d %v, want ErrRealmCopy", c.name, n, err)
				}
			}
			if rs, _ := f.realm.RealmReceipts(ctx, p); len(rs) != 0 {
				t.Fatalf("a refused copy wrote %v", rs)
			}
			if _, ok := f.dueOf(t, p, ws); ok {
				t.Fatal("a refused copy wrote receipt_due")
			}
		})
	}
}

// TestBuildRealmReceipts: 8.2's grouping and states, without a store. A work
// and a travel entry of one label on one day stay two rows (107 FR-27); two
// topics on one day sum into one; a returned period is not final; a day
// past its freeze with no row is frozen; a long workspace name is cut to 200.
func TestBuildRealmReceipts(t *testing.T) {
	hs := HoursSettings{Period: HoursPeriodWeek, GraceDays: 2, TZ: "UTC"}
	periods := []HoursPeriod{{Member: "HUM-1", Start: "2026-09-14", End: "2026-09-20", State: HoursReturned,
		Note: "check", DecidedBy: "HUM-2", DecidedAt: receiptDecAt}}
	in := []realmCopyEntry{
		{Day: "2026-09-08", Target: "t:a", Kind: "work", Minutes: 60},
		{Day: "2026-09-08", Target: "t:b", Kind: "work", Minutes: 30},
		{Day: "2026-09-08", Target: "t:a", Kind: "travel", Minutes: 20},
		{Day: "2026-09-16", Target: "job:j1", Kind: "work", Minutes: 300},
		{Day: "2026-09-16", Target: "ws", Kind: "absence", Minutes: 100},
	}
	long := strings.Repeat("ä", 250)
	rows, lastOpen := buildRealmReceipts(in, periods, hs, "W", long, map[string]string{"HUM-2": "Boss"}, receiptLeave)
	var got []string
	for _, r := range rows {
		got = append(got, fmt.Sprintf("%s|%s|%s|%d|%s|%s", r.Day, r.Label, r.Kind, r.Minutes, r.ApprovalState, r.ApproverName))
	}
	want := []string{
		"2026-09-08|topic|travel|20|frozen|",
		"2026-09-08|topic|work|90|frozen|",
		"2026-09-16|job|work|300|returned|Boss",
		"2026-09-16|workspace|absence|100|returned|Boss",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("rows:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if lastOpen != "2026-09-16" {
		t.Fatalf("lastOpen %q, want the first returned day", lastOpen)
	}
	if n := len([]rune(rows[0].WorkspaceName)); n != realmTextMax {
		t.Fatalf("workspace name %d characters, want %d", n, realmTextMax)
	}
	for target, want := range map[string]string{"t:x": "topic", "ch:x": "channel", "dm:HUM-1": "direct message",
		"cal:e": "meeting", "ws": "workspace", "job:1": "job", "zz": "other"} {
		if got := RealmReceiptLabel(target); got != want {
			t.Errorf("label of %q = %q, want %q", target, got, want)
		}
	}
}
