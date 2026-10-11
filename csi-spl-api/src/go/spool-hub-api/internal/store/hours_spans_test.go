package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 107 v2.3 section 3.4 (spec 118 v1.1 5.2, 5.3; owner msg 23d782e1,
// Q1 A, Q2 A, Q3 A): rdb 0176's hours_entry_spans and the member_scope guard.
// The store half runs on Memory and Postgres; the RLS half on Postgres only
// (SPOOL_TEST_PG_DSN, a non-superuser role so RLS binds).

const hoursOther = "44444444-4444-4444-8444-444444444444"

func hspan(start, end time.Time, src string) HoursSpan {
	return HoursSpan{Start: start, End: end, Src: src}
}

func spansString(ss []HoursEntrySpan) string {
	out := ""
	for _, s := range ss {
		out += fmt.Sprintf("%s %s %s-%s %s; ", s.Day, s.Target, s.Start.Format("15:04"), s.End.Format("15:04"), s.Src)
	}
	return out
}

// TestHoursSpansWrite: spans are written with their entry; a timer span adds,
// activity spans replace the entry's activity spans, and one overlapping a
// stored span is skipped (the approval saves); an entry without spans
// is valid (Q2 A); an overlap with another span of the member, on another
// target too, is ErrHoursOverlap and writes nothing of the batch; another
// member and another workspace never conflict; deleting the entry deletes
// its spans; bad spans are ErrHoursBad.
func TestHoursSpansWrite(t *testing.T) {
	ctx := context.Background()
	at := func(h, m int) time.Time { return time.Date(2026, 10, 7, h, m, 0, 0, time.UTC) }
	const day = "2026-10-07"
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			h, tid, other := hoursStore(t, st), newTenant(t, st), newTenant(t, st)
			put := func(tenant, member string, es ...HoursEntry) error {
				return h.PutHoursEntries(ctx, tenant, member, es, member, hoursT0)
			}
			read := func(tenant, member string) string {
				t.Helper()
				ss, err := h.HoursEntrySpans(ctx, tenant, member, day, day)
				if err != nil {
					t.Fatal(err)
				}
				return spansString(ss)
			}
			// An approved suggestion with its two blocks; a typed row without times.
			a := hoursEntry(day, "t:a", 60)
			a.Spans = []HoursSpan{hspan(at(10, 0), at(10, 30), HoursSpanActivity), hspan(at(9, 0), at(9, 30), HoursSpanActivity)}
			if err := put(tid, hoursMember, a, hoursEntry(day, "ws", 15)); err != nil {
				t.Fatal(err)
			}
			want := "2026-10-07 t:a 09:00-09:30 activity; 2026-10-07 t:a 10:00-10:30 activity; "
			if got := read(tid, hoursMember); got != want {
				t.Fatalf("after the approval: %s\nwant %s", got, want)
			}
			// A stopped timer adds to t:a; the minutes are the caller's.
			tm := hoursEntry(day, "t:a", 90)
			tm.Spans = []HoursSpan{hspan(at(11, 0), at(11, 30), HoursSpanTimer)}
			if err := put(tid, hoursMember, tm); err != nil {
				t.Fatal(err)
			}
			// The suggestion recomputed: its blocks replace the activity
			// spans, the timer span stays.
			a.Minutes, a.Spans = 75, []HoursSpan{hspan(at(9, 0), at(9, 45), HoursSpanActivity)}
			if err := put(tid, hoursMember, a); err != nil {
				t.Fatal(err)
			}
			want = "2026-10-07 t:a 09:00-09:45 activity; 2026-10-07 t:a 11:00-11:30 timer; "
			if got := read(tid, hoursMember); got != want {
				t.Fatalf("after the replace: %s\nwant %s", got, want)
			}
			// An activity block overlapping the member's timer is skipped, not
			// refused: the approval saves, the block's minutes stay unplaced.
			a.Spans = append(a.Spans, hspan(at(11, 10), at(11, 20), HoursSpanActivity))
			if err := put(tid, hoursMember, a); err != nil {
				t.Fatalf("an activity block over the timer: %v", err)
			}
			if got := read(tid, hoursMember); got != want {
				t.Fatalf("after the skipped block: %s\nwant %s", got, want)
			}
			// A span overlapping t:a's timer, on another target: refused, and
			// the entry of the same write with it.
			b := hoursEntry(day, "t:b", 20)
			b.Spans = []HoursSpan{hspan(at(11, 20), at(11, 40), HoursSpanTimer)}
			if err := put(tid, hoursMember, b); !errors.Is(err, ErrHoursOverlap) {
				t.Fatalf("an overlap across targets: %v, want ErrHoursOverlap", err)
			}
			es, _ := h.HoursEntries(ctx, tid, hoursMember, day, day)
			if len(es) != 2 {
				t.Fatalf("a refused write left entries %+v", es)
			}
			// Two overlapping spans in one write are refused too.
			b.Spans = []HoursSpan{hspan(at(12, 0), at(12, 30), HoursSpanTimer), hspan(at(12, 29), at(13, 0), HoursSpanTimer)}
			if err := put(tid, hoursMember, b); !errors.Is(err, ErrHoursOverlap) {
				t.Fatalf("an overlap inside one write: %v", err)
			}
			// Touching spans do not overlap ([a,b) + [b,c)).
			b.Spans = []HoursSpan{hspan(at(11, 30), at(11, 50), HoursSpanTimer)}
			if err := put(tid, hoursMember, b); err != nil {
				t.Fatalf("touching spans: %v", err)
			}
			// The same times for another member, and in another workspace: allowed.
			o := hoursEntry(day, "t:b", 30)
			o.Spans = []HoursSpan{hspan(at(11, 0), at(11, 30), HoursSpanTimer)}
			if err := put(tid, hoursOther, o); err != nil {
				t.Fatalf("another member: %v", err)
			}
			if err := put(other, hoursMember, o); err != nil {
				t.Fatalf("another workspace: %v", err)
			}
			if got := read(tid, hoursOther); got != "2026-10-07 t:b 11:00-11:30 timer; " {
				t.Fatalf("the other member reads %s", got)
			}
			// Editing minutes only leaves the spans; deleting the entry takes them.
			if err := put(tid, hoursMember, hoursEntry(day, "t:a", 10)); err != nil {
				t.Fatal(err)
			}
			if err := h.DeleteHoursEntry(ctx, tid, hoursMember, day, "t:a", hoursT0); err != nil {
				t.Fatal(err)
			}
			if got := read(tid, hoursMember); got != "2026-10-07 t:b 11:30-11:50 timer; " {
				t.Fatalf("after the delete: %s", got)
			}
			for _, sp := range []HoursSpan{
				hspan(at(14, 0).Add(30*time.Second), at(14, 30), HoursSpanTimer),
				hspan(at(14, 30), at(14, 30), HoursSpanTimer),
				hspan(at(14, 30), at(14, 0), HoursSpanTimer),
				hspan(at(0, 0), at(0, 0).Add(1441*time.Minute), HoursSpanTimer),
				hspan(at(14, 0), at(14, 30), "guess"),
			} {
				e := hoursEntry(day, "t:c", 30)
				e.Spans = []HoursSpan{sp}
				if err := put(tid, hoursMember, e); !errors.Is(err, ErrHoursBad) {
					t.Errorf("span %+v: %v, want ErrHoursBad", sp, err)
				}
			}
		})
	}
}

// memberScopeCounts reads tenant's rows of the three guarded tables with no
// member_id predicate, in one fresh transaction under scope: "member:<id>"
// (tenant + member), "tenant" (tenant only) or "member-empty" (tenant +
// app.member_id set to the empty string).
func memberScopeCounts(t *testing.T, pg *Postgres, scope, tenant string) string {
	t.Helper()
	ctx := context.Background()
	out := ""
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "tenant":
			_, err = tx.Exec(ctx, pgScopeTenant, tenant)
		case scope == "member-empty":
			_, err = tx.Exec(ctx, pgScopeMember, tenant, "")
		default:
			_, err = tx.Exec(ctx, pgScopeMember, tenant, scope[len("member:"):])
		}
		if err != nil {
			return err
		}
		for _, tb := range []string{"hours_entries", "hours_entry_spans", "hours_minutes"} {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+tb+` WHERE tenant_id = $1`, tenant).Scan(&n); err != nil {
				return err
			}
			out += fmt.Sprintf("%s=%d ", tb, n)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("%s: %v", scope, err)
	}
	return out
}

// seedMemberHours writes one entry with one span and one minute for member.
func seedMemberHours(t *testing.T, pg *Postgres, tenant, member string, at time.Time) {
	t.Helper()
	e := hoursEntry(at.Format("2006-01-02"), "t:a", 30)
	e.Spans = []HoursSpan{hspan(at, at.Add(30*time.Minute), HoursSpanTimer)}
	if err := pg.PutHoursEntries(context.Background(), tenant, member, []HoursEntry{e}, member, hoursT0); err != nil {
		t.Fatal(err)
	}
	if err := pg.UpsertHoursMinutes(context.Background(), tenant, member,
		[]HoursMinute{{At: at, Target: "t:a", Src: HoursSrcPost, TZ: "UTC"}}); err != nil {
		t.Fatal(err)
	}
}

// TestRLSHoursMemberScope (Q3 A; spec 118 T-RLS1 in the database): under
// member P's scope a statement with NO member_id predicate reads only P's
// rows of hours_entries, hours_entry_spans and hours_minutes; a second member
// Q with no rows reads 0; writes naming Q fail WITH CHECK (42501) and an
// UPDATE or DELETE of Q's rows touches none. The tenant scope alone, and an
// empty member, still read every member (the team view, the sweep). Another
// tenant's scope reads 0 with P set (tenant isolation holds under the member
// scope). CONTROL: with member_scope dropped (rolled back), P's scope reads
// both members' rows, so the counts above are the policy's.
func TestRLSHoursMemberScope(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	at := time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)
	seedMemberHours(t, pg, t1, hoursMember, at)
	seedMemberHours(t, pg, t1, hoursOther, at)
	one, two, none := "hours_entries=1 hours_entry_spans=1 hours_minutes=1 ",
		"hours_entries=2 hours_entry_spans=2 hours_minutes=2 ", "hours_entries=0 hours_entry_spans=0 hours_minutes=0 "
	for _, c := range []struct{ scope, want string }{
		{"member:" + hoursMember, one}, {"member:HUM-nobody", none},
		{"tenant", two}, {"member-empty", two},
	} {
		if got := memberScopeCounts(t, pg, c.scope, t1); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	if got := memberScopeCounts(t, pg, "member:"+hoursMember, t2); got != none {
		t.Errorf("t2 with P's member scope reads t1's? %s", got)
	}
	// The store's own reads, under P: only P's rows.
	if ss, err := pg.HoursEntrySpans(ctx, t1, hoursMember, "2026-10-07", "2026-10-07"); err != nil || len(ss) != 1 {
		t.Errorf("P's spans: %d (%v)", len(ss), err)
	}
	// Writes under P's scope that name Q.
	day := "2026-10-08"
	for _, w := range []string{
		`INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by) VALUES ($1, $2, '` + day + `', 'ws', 1, 'approved', $2)`,
		`INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz) VALUES ($1, $2, '2026-10-08T09:00:00Z', 'ws', 'post', 'UTC')`,
		`INSERT INTO hours_entry_spans (tenant_id, member_id, day, target, start_at, end_at, src) VALUES ($1, $2, '2026-10-07', 't:a', '2026-10-07T13:00:00Z', '2026-10-07T13:30:00Z', 'timer')`,
	} {
		if _, err := pg.execMember(ctx, t1, hoursMember, w, t1, hoursOther); pgCode(err) != "42501" {
			t.Errorf("a Q row written under P's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	for _, tb := range []string{"hours_entries", "hours_entry_spans", "hours_minutes"} {
		tag, err := pg.execMember(ctx, t1, hoursMember, `UPDATE `+tb+` SET member_id = member_id WHERE tenant_id = $1 AND member_id = $2`, t1, hoursOther)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("P's scope updated %d %s rows of Q: %v", tag.RowsAffected(), tb, err)
		}
		tag, err = pg.execMember(ctx, t1, hoursMember, `DELETE FROM `+tb+` WHERE tenant_id = $1 AND member_id = $2`, t1, hoursOther)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("P's scope deleted %d %s rows of Q: %v", tag.RowsAffected(), tb, err)
		}
	}
	if got := memberScopeCounts(t, pg, "tenant", t1); got != two {
		t.Fatalf("after P's writes t1 holds %s, want %s", got, two)
	}
	// The store refuses an empty member before Postgres.
	if _, err := pg.HoursEntrySpans(ctx, t1, " ", "2026-10-07", "2026-10-07"); !errors.Is(err, ErrNoMember) {
		t.Errorf("an empty member: %v, want ErrNoMember", err)
	}
	// CONTROL: member_scope dropped in a rolled-back transaction.
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP POLICY member_scope ON hours_entries`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgScopeMember, t1, hoursMember); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM hours_entries WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 2 {
		t.Fatalf("CONTROL: without member_scope P's scope read %d entries, want 2", n)
	}
}

// TestRLSHoursSpansTenant: hours_entry_spans in the 0098 shape: t2's scope,
// an empty and no scope read none of t1's spans; the operator reads them; a
// t1 span written under t2's scope fails WITH CHECK; a tenant delete takes
// them. The CHECKs of rdb 0176 refuse what they must (23514).
func TestRLSHoursSpansTenant(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	at := time.Date(2026, 10, 7, 9, 0, 0, 0, time.UTC)
	seedMemberHours(t, pg, t1, hoursMember, at)
	count := func(scope string) int {
		t.Helper()
		var n int
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
			switch scope {
			case "operator":
				_, err = tx.Exec(ctx, pgScopeOperator)
			case "empty":
				_, err = tx.Exec(ctx, pgScopeTenant, "")
			case "none":
			default:
				_, err = tx.Exec(ctx, pgScopeTenant, scope)
			}
			if err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM hours_entry_spans WHERE tenant_id = $1`, t1).Scan(&n)
		})
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	for scope, want := range map[string]int{t2: 0, "empty": 0, "none": 0, t1: 1, "operator": 1} {
		if got := count(scope); got != want {
			t.Errorf("scope %s reads %d spans of t1, want %d", scope, got, want)
		}
	}
	ins := func(start, end, src string) string {
		return `INSERT INTO hours_entry_spans (tenant_id, member_id, day, target, start_at, end_at, src)
			VALUES ($1, '` + hoursMember + `', '2026-10-07', 't:a', '` + start + `', '` + end + `', '` + src + `')`
	}
	if _, err := pg.execTenant(ctx, t2, ins("2026-10-07T15:00:00Z", "2026-10-07T15:30:00Z", "timer"), t1); pgCode(err) != "42501" {
		t.Errorf("a t1 span under t2's scope: %v, want 42501", err)
	}
	for _, c := range []struct {
		name, sql string
		code      string
	}{
		{"ok", ins("2026-10-07T15:00:00Z", "2026-10-07T15:30:00Z", "plan"), ""},
		{"seconds", ins("2026-10-07T16:00:30Z", "2026-10-07T16:30:00Z", "timer"), "23514"},
		{"end before start", ins("2026-10-07T17:30:00Z", "2026-10-07T17:00:00Z", "timer"), "23514"},
		{"over 1440", ins("2026-10-06T00:00:00Z", "2026-10-07T00:01:00Z", "timer"), "23514"},
		{"src", ins("2026-10-07T18:00:00Z", "2026-10-07T18:30:00Z", "guess"), "23514"},
		{"no entry", `INSERT INTO hours_entry_spans (tenant_id, member_id, day, target, start_at, end_at, src)
			VALUES ($1, 'HUM-x', '2026-10-07', 't:a', '2026-10-07T19:00:00Z', '2026-10-07T19:30:00Z', 'timer')`, "23503"},
		{"overlap", ins("2026-10-07T09:15:00Z", "2026-10-07T09:45:00Z", "timer"), "23P01"},
	} {
		_, err := pg.execTenant(ctx, t1, c.sql, t1)
		if pgCode(err) != c.code {
			t.Errorf("%s: %v, want code %q", c.name, err, c.code)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, t1)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := count("operator"); got != 0 {
		t.Fatalf("after the tenant delete: %d spans", got)
	}
}
