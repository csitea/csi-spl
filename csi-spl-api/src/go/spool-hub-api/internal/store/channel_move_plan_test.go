// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
)

// Spec 169 row T4: PlanChannelMove. C1 (plan changes nothing: the row count
// of every tenant table is equal before and after) runs on Postgres; C7
// (Q6 = A: an issue linked to topics in two channels refuses the move,
// naming it) runs on both drivers. Each lands with its red control. Row T4b:
// C22 (R1, a box not pinned in <DST> is listed) and C23 (W2, a seated agent
// with no <DST> desk refuses, naming it) run on both drivers.

// movePlanFix is <SRC> with a moving channel and a staying one, and <DST>.
type movePlanFix struct {
	src, dst, mv, stay    string
	tA, tA2, tB, thread   string
	cardA, cardB, staying string
	shared, own           Issue // shared: own topic in mv, linked to tB; own: only in mv
}

func moveCatalogue() ([]MoveTable, map[string]string) {
	var out []MoveTable
	for _, e := range channelmove.Catalogue {
		out = append(out, MoveTable{Table: e.Table, Class: string(e.Class), Set: e.Set, Refs: e.Refs})
	}
	return out, channelmove.Binds
}

func (f movePlanFix) req() ChannelMovePlanRequest {
	tables, binds := moveCatalogue()
	return ChannelMovePlanRequest{Src: f.src, Channel: f.mv, Dst: f.dst, Tables: tables, BindTypes: binds}
}

func seedMovePlan(t *testing.T, s Store) movePlanFix {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	f := movePlanFix{src: newTenant(t, s), dst: newTenant(t, s), mv: uid("mv-"), stay: uid("st-"),
		tA: uuid4(), tA2: uuid4(), tB: uuid4(), thread: uuid4()}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, ch := range []string{f.mv, f.stay} {
		must(s.CreateChannel(ctx, Channel{TenantID: f.src, ChannelID: ch, Name: ch, CreatedBy: "HUM-1", CreatedAt: now}))
	}
	must(s.AddChannelHumans(ctx, f.src, f.mv, []string{"HUM-1"}, "HUM-1", now))
	must(s.PutPin(ctx, f.dst, "box-a", pubkey(), false, now, now)) // msgFor's from_box: only C22 is about pins
	post := func(task, parent, ch, body string, at time.Time) string {
		m := msgFor(f.src, task, "box-a", at, at, "env-"+uuid4())
		m.Channel, m.ParentTaskID, m.Body = ch, parent, body
		_, err := s.InsertMessage(ctx, m)
		must(err)
		return m.MsgID
	}
	f.cardA = post(f.tA, "", f.mv, "topic A", now)
	post(f.tA, "", f.mv, "reply in A", now.Add(time.Second))
	post(f.thread, f.tA, "", "a thread under A, no channel on the row", now.Add(2*time.Second))
	post(f.tA2, "", f.mv, "topic A2", now.Add(3*time.Second))
	f.cardB = post(f.tB, "", f.stay, "topic B", now.Add(4*time.Second))
	f.staying = post(f.tB, "", f.stay, "context:\nsee /t/"+f.tA+" for the plan\nunrelated line", now.Add(5*time.Second))
	is, ok := s.(interface {
		Issues
		IssueDiscussions
	})
	if !ok {
		t.Fatalf("%T keeps no issues", s)
	}
	var err error
	f.shared, err = is.CreateIssue(ctx, Issue{TenantID: f.src, Title: "shared", TaskID: f.tA, Discussions: []string{f.tA}, CreatedBy: "HUM-1"}, now)
	must(err)
	_, err = is.LinkIssueDiscussion(ctx, f.src, f.shared.Number, f.tB, "HUM-1", now)
	must(err)
	f.own, err = is.CreateIssue(ctx, Issue{TenantID: f.src, Title: "own", TaskID: f.tA2, Discussions: []string{f.tA2}, CreatedBy: "HUM-1"}, now)
	must(err)
	return f
}

func planOf(t *testing.T, s Store, req ChannelMovePlanRequest) ChannelMovePlan {
	t.Helper()
	pl, ok := s.(ChannelMovePlanner)
	if !ok {
		t.Fatalf("%T has no PlanChannelMove", s)
	}
	p, err := pl.PlanChannelMove(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func hasShared(p ChannelMovePlan, kind, id string) bool {
	for _, s := range p.Shared {
		if s.Kind == kind && s.ID == id {
			return true
		}
	}
	return false
}

func containsInt(l []int, v int) bool {
	for _, x := range l {
		if x == v {
			return true
		}
	}
	return false
}

// TestPlanChannelMoveC7SharedIssue: the issue whose own topic is in the
// channel and that a discussion links to a topic of a staying channel is
// a shared item, named by its key; the issue only the channel uses is not.
func TestPlanChannelMoveC7SharedIssue(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := seedMovePlan(t, s)
			p := planOf(t, s, f.req())
			sharedKey := planIssueKey(f.shared.Prefix, f.shared.Number)
			ownKey := planIssueKey(f.own.Prefix, f.own.Number)
			if !p.Refused() || !hasShared(p, "issue", sharedKey) {
				t.Fatalf("plan must refuse naming %s, got shared %+v", sharedKey, p.Shared)
			}
			if hasShared(p, "issue", ownKey) {
				t.Errorf("%s is the channel's alone, yet listed shared: %+v", ownKey, p.Shared)
			}
			stop := strings.Join(p.Stops(), "\n")
			if !strings.Contains(stop, sharedKey) || !strings.Contains(stop, f.tB) || !strings.Contains(stop, "#"+f.stay) {
				t.Errorf("the stop line must name the issue, the other topic and its channel, got %q", stop)
			}
			if !containsInt(p.Binds.Numbers, f.shared.Number) || !containsInt(p.Binds.Numbers, f.own.Number) {
				t.Errorf("both issues are in the set (M7), got %v", p.Binds.Numbers)
			}
			// CONTROL: without the shared check the move goes on, and the
			// shared issue is in the set while its link to the staying topic
			// is not: the move would take the issue from the other channel.
			req := f.req()
			req.noSharedCheck = true
			c := planOf(t, s, req)
			if c.Refused() {
				t.Fatalf("CONTROL: with the check removed the plan still refuses: %v", c.Stops())
			}
			if !containsInt(c.Binds.Numbers, f.shared.Number) || contains(c.Binds.Tasks, f.tB) {
				t.Fatalf("CONTROL: want %d in the set and %s outside it, got %v / %v", f.shared.Number, f.tB, c.Binds.Numbers, c.Binds.Tasks)
			}
		})
	}
}

// TestPlanChannelMoveSetAndMentions: the walk finds the channel's posts and
// the channel-less thread under its topic, the staying post that links a
// moved topic is a mention (listed, not edited), and the channel's member
// who is not a <DST> member is leaving unless kept.
func TestPlanChannelMoveSetAndMentions(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := seedMovePlan(t, s)
			p := planOf(t, s, f.req())
			for _, task := range []string{f.tA, f.tA2, f.thread, f.cardA} {
				if !contains(p.Binds.Tasks, task) {
					t.Errorf("task %s missing from the set %v", task, p.Binds.Tasks)
				}
			}
			if contains(p.Binds.Tasks, f.tB) || contains(p.Binds.Msgs, f.cardB) || len(p.Binds.Msgs) != 4 {
				t.Errorf("want the 4 posts of the channel and its thread, got %v", p.Binds.Msgs)
			}
			if len(p.Mentions) != 1 || p.Mentions[0].MsgID != f.staying || p.Mentions[0].Line != "see /t/"+f.tA+" for the plan" || p.Mentions[0].Channel != f.stay {
				t.Errorf("want one mention, the staying post's one line, got %+v", p.Mentions)
			}
			if !contains(p.Binds.MarkKeys, "ch:"+f.mv) || !contains(p.Binds.Targets, "t:"+f.tA) || !contains(p.Binds.IDLikes, "%"+f.tA+"%") {
				t.Errorf("derived binds incomplete: %v / %v", p.Binds.MarkKeys, p.Binds.Targets)
			}
			if len(p.Leaving) != 1 || p.Leaving[0] != "HUM-1" {
				t.Errorf("HUM-1 is not a <DST> member: want leaving [HUM-1], got %v", p.Leaving)
			}
			req := f.req()
			req.Keep = []string{"HUM-1"}
			if k := planOf(t, s, req); len(k.Leaving) != 0 {
				t.Errorf("a kept member is not leaving, got %v", k.Leaving)
			}
		})
	}
}

func TestPlanChannelMoveRequest(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := seedMovePlan(t, s)
			pl := s.(ChannelMovePlanner)
			ctx := context.Background()
			req := f.req()
			req.Dst = f.src
			if _, err := pl.PlanChannelMove(ctx, req); !errors.Is(err, ErrMoveRequest) {
				t.Errorf("same workspace on both sides: want ErrMoveRequest, got %v", err)
			}
			req = f.req()
			req.Tables = append(req.Tables, MoveTable{Table: "channels", Class: "moved", Set: "channel_id = @nope"})
			if _, err := pl.PlanChannelMove(ctx, req); !errors.Is(err, ErrMoveRequest) {
				t.Errorf("a bind with no type: want ErrMoveRequest, got %v", err)
			}
			req = f.req()
			req.Channel = uid("gone-")
			if _, err := pl.PlanChannelMove(ctx, req); !errors.Is(err, ErrNotFound) {
				t.Errorf("no such channel: want ErrNotFound, got %v", err)
			}
		})
	}
}

// TestPlanChannelMoveC22UnpinnedBox: R1. Each from_box of the set's rows
// needs a live pin in <DST>: a box with none, with a revoked one or pinned
// only in <SRC> is listed and refuses, also for a channel-less thread row the
// walk found. A box only a staying post names, and a row with no box, are not.
func TestPlanChannelMoveC22UnpinnedBox(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := seedMovePlan(t, s)
			ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
			post := func(task, parent, ch, box string) {
				t.Helper()
				m := msgFor(f.src, task, "box-a", now, now, "env-"+uuid4())
				m.Channel, m.ParentTaskID, m.FromBox = ch, parent, box
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			pin := func(tenant, box string) {
				t.Helper()
				if err := s.PutPin(ctx, tenant, box, pubkey(), false, now, now); err != nil {
					t.Fatal(err)
				}
			}
			req := f.req()
			req.noSharedCheck = true // the shared issue is C7's; here only the pins
			if p := planOf(t, s, req); p.Refused() || len(p.MissingPins) != 0 {
				t.Fatalf("every box of the set is pinned: want no stop, got %q", p.Stops())
			}
			post(f.tA, "", f.mv, "box-none")
			post(uuid4(), f.tA, "", "box-thread")
			post(f.tA, "", f.mv, "box-revoked")
			post(f.tA, "", f.mv, "box-src-only")
			post(f.tA, "", f.mv, "box-good")
			post(f.tA, "", f.mv, "")
			post(f.tB, "", f.stay, "box-staying")
			pin(f.dst, "box-good")
			pin(f.dst, "box-revoked")
			if err := s.RevokePin(ctx, f.dst, "box-revoked", now.Add(time.Second), now); err != nil {
				t.Fatal(err)
			}
			pin(f.src, "box-src-only")
			pin(f.src, "box-staying")
			p := planOf(t, s, req)
			want := []string{"box-none", "box-revoked", "box-src-only", "box-thread"}
			if strings.Join(p.MissingPins, " ") != strings.Join(want, " ") {
				t.Fatalf("want missing pins %v, got %v", want, p.MissingPins)
			}
			if !p.Refused() {
				t.Errorf("an unpinned box must refuse the move")
			}
			line := "box box-none is not pinned in " + f.dst + " (R1)"
			if !contains(p.Stops(), line) {
				t.Errorf("want the stop %q, got %q", line, p.Stops())
			}
			for _, b := range []string{"box-none", "box-src-only", "box-thread"} {
				pin(f.dst, b)
			}
			if err := s.PutPin(ctx, f.dst, "box-revoked", pubkey(), true, now.Add(2*time.Second), now); err != nil {
				t.Fatal(err)
			}
			if p := planOf(t, s, req); p.Refused() {
				t.Errorf("all pinned now: want no stop, got %q", p.Stops())
			}
			// CONTROL: without the check the unpinned box passes plan unseen.
			post(f.tA, "", f.mv, "box-late")
			req.noPinCheck = true
			if c := planOf(t, s, req); c.Refused() || len(c.MissingPins) != 0 {
				t.Fatalf("CONTROL: with the check removed the box is still listed: %v", c.MissingPins)
			}
			req.noPinCheck = false
			if p := planOf(t, s, req); len(p.MissingPins) != 1 || p.MissingPins[0] != "box-late" {
				t.Fatalf("CONTROL: the same seed with the check must list box-late, got %v", p.MissingPins)
			}
		})
	}
}

// TestPlanChannelMoveC23MissingDesk: W2. Each agent seated in the channel, by
// invite or as a channel's dedicated agent, needs a roster row on its box in
// <DST>; the plan refuses naming the missing ones. A desk on another box, in
// <SRC> only, or one that left the roster (its agent_seats row outlives it) is
// no desk. A removed seat and a seat in a staying channel need none.
func TestPlanChannelMoveC23MissingDesk(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := seedMovePlan(t, s)
			ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
			must := func(err error) {
				t.Helper()
				if err != nil {
					t.Fatal(err)
				}
			}
			ds, ok := s.(DedicatedStore)
			if !ok {
				t.Fatalf("%T keeps no dedicated agents", s)
			}
			req := f.req()
			req.noSharedCheck = true // the shared issue is C7's; here only the desks
			for _, a := range []string{"c-101", "c-102", "c-103", "c-104", "c-105"} {
				must(s.InviteChannelAgent(ctx, f.src, f.mv, "box-desk", a, now))
			}
			_, err := ds.SetDedicatedBinding(ctx, DedicatedBinding{TenantID: f.src, AgentID: "c-106", BoxID: "box-desk",
				ScopeType: ScopeChannel, ScopeID: f.mv, BoundBy: "HUM-1"})
			must(err)
			must(s.RemoveChannelAgent(ctx, f.src, f.mv, "box-desk", "c-107", now))
			must(s.InviteChannelAgent(ctx, f.src, f.stay, "box-desk", "c-108", now))
			must(s.SetRoster(ctx, f.src, "box-desk", []string{"c-101", "c-102", "c-103", "c-104", "c-105", "c-106"}, now))
			must(s.SetRoster(ctx, f.dst, "box-desk", []string{"c-101", "c-105"}, now))
			must(s.SetRoster(ctx, f.dst, "box-other", []string{"c-102"}, now))
			must(s.SetRoster(ctx, f.dst, "box-desk", []string{"c-101"}, now.Add(time.Second))) // c-105 left: only its agent_seats row stays
			p := planOf(t, s, req)
			want := []MoveSeat{{"c-102", "box-desk"}, {"c-103", "box-desk"}, {"c-104", "box-desk"}, {"c-105", "box-desk"}, {"c-106", "box-desk"}}
			if fmt.Sprint(p.MissingDesks) != fmt.Sprint(want) {
				t.Fatalf("want missing desks %v, got %v", want, p.MissingDesks)
			}
			if !p.Refused() {
				t.Errorf("a seat with no desk must refuse the move")
			}
			line := "seat c-106 on box-desk has no desk in " + f.dst + " (W2)"
			if !contains(p.Stops(), line) {
				t.Errorf("want the stop %q, got %q", line, p.Stops())
			}
			// CONTROL: without the check the same seats pass plan unseen.
			req.noDeskCheck = true
			if c := planOf(t, s, req); c.Refused() || len(c.MissingDesks) != 0 {
				t.Fatalf("CONTROL: with the check removed the desks are still listed: %v", c.MissingDesks)
			}
			req.noDeskCheck = false
			must(s.SetRoster(ctx, f.dst, "box-desk", []string{"c-101", "c-102", "c-103", "c-104", "c-105", "c-106"}, now.Add(2*time.Second)))
			if p := planOf(t, s, req); p.Refused() {
				t.Errorf("every seat has its desk now: want no stop, got %q", p.Stops())
			}
		})
	}
}

// tenantTableCounts is the row count of every table with tenant_id, all
// tenants, read under the operator scope.
func tenantTableCounts(t *testing.T, pg *Postgres) map[string]int64 {
	t.Helper()
	ctx := context.Background()
	out := map[string]int64{}
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		var tables []string
		err := eachRow(ctx, tx, `SELECT c.table_name FROM information_schema.columns c
			JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
			WHERE c.table_schema = current_schema() AND c.column_name = 'tenant_id' AND t.table_type = 'BASE TABLE'
			ORDER BY 1`, nil, func(r pgx.Rows) error {
			var n string
			err := r.Scan(&n)
			tables = append(tables, n)
			return err
		})
		for _, tb := range tables {
			var n int64
			if err == nil {
				err = tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()).Scan(&n)
			}
			out[tb] = n
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(out) < 100 {
		t.Fatalf("only %d tenant tables read: the count is not every tenant table", len(out))
	}
	return out
}

func countDiff(before, after map[string]int64) []string {
	var out []string
	for tb, n := range after {
		if before[tb] != n {
			out = append(out, fmt.Sprintf("%s %d -> %d", tb, before[tb], n))
		}
	}
	return out
}

// seedMovePlanRows adds, on Postgres, the rows of the set Memory cannot
// hold: a calendar event on topic A, hours rows naming the channel and
// topic A (HUM-77, inside an approved period), and a Qto doc a post of the
// channel links.
func seedMovePlanRows(t *testing.T, pg *Postgres, f movePlanFix) (doc string) {
	t.Helper()
	ctx := context.Background()
	day := time.Date(2026, 10, 14, 0, 0, 0, 0, time.UTC)
	err := pg.inTenant(ctx, f.src, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO calendar_events (tenant_id, title, kind, starts_at, ends_at, creator_type, creator_id, topic_id)
			VALUES ($1, 'release', 'release', now(), now(), 'human', 'HUM-1', $2)`, f.src, f.tA); err != nil {
			return err
		}
		for _, target := range []string{"t:" + f.tA, "ch:" + f.mv} {
			if _, err := tx.Exec(ctx, `INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by)
				VALUES ($1, 'HUM-77', $2, $3, 60, 'approved', 'HUM-77')`, f.src, day, target); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, minutes, decided_by)
			VALUES ($1, 'HUM-77', $2, $3, 'approved', 120, 'HUM-1')`, f.src, day.AddDate(0, 0, -3), day.AddDate(0, 0, 3)); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `INSERT INTO workspace_doc (tenant_id, title) VALUES ($1, 'plan doc') RETURNING id::text`, f.src).Scan(&doc); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord) VALUES ($1, $2, NULL, 1)`, f.src, doc)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	m := msgFor(f.src, f.tA, "box-a", time.Now().UTC(), time.Now().UTC(), "env-"+uuid4())
	m.Channel, m.Body = f.mv, "the doc: /d/"+doc
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	return doc
}

// TestPlanChannelMoveC1ChangesNothing: plan of a seeded channel finds its
// set (posts, the issue, the event, the hours rows, the doc) and the row
// count of every tenant table is the same before and after.
func TestPlanChannelMoveC1ChangesNothing(t *testing.T) {
	pg := rlsStore(t)
	f := seedMovePlan(t, pg)
	doc := seedMovePlanRows(t, pg, f)
	before := tenantTableCounts(t, pg)
	p := planOf(t, pg, f.req())
	if d := countDiff(before, tenantTableCounts(t, pg)); len(d) > 0 {
		t.Fatalf("plan changed rows: %v", d)
	}
	want := map[string]int{"channels": 1, "messages": 5, "calendar_events": 1, "hours_entries": 2, "issues": 2, "issue_discussions": 3, "workspace_doc": 1, "channel_humans": 1}
	for _, c := range p.Counts {
		if n, ok := want[c.Table]; ok && c.Set != n {
			t.Errorf("%s: want %d rows of the set, got %d", c.Table, n, c.Set)
		}
		delete(want, c.Table)
	}
	if len(want) > 0 {
		t.Errorf("no count for %v", want)
	}
	if len(p.Counts) < 40 || !contains(p.Binds.Docs, doc) || len(p.Binds.Events) != 1 {
		t.Errorf("plan read %d catalogue tables, docs %v, events %v", len(p.Counts), p.Binds.Docs, p.Binds.Events)
	}
}

// TestPlanChannelMoveC1Control: the two halves of C1's red control. A plan
// that writes its journal in <SRC> is caught by the count, and plan's own
// transaction refuses any write at the server.
func TestPlanChannelMoveC1Control(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	f := seedMovePlan(t, pg)
	before := tenantTableCounts(t, pg)
	planOf(t, pg, f.req())
	if err := pg.CreateChannel(ctx, Channel{TenantID: f.src, ChannelID: uid("journal-"), Name: "journal", CreatedBy: "HUM-1", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if d := strings.Join(countDiff(before, tenantTableCounts(t, pg)), "; "); !strings.Contains(d, "channels ") {
		t.Fatalf("CONTROL: a plan that writes a <SRC> row must show in the count, got %v", d)
	}
	err := pg.planRead(ctx, f.src, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ($1, $2, 'x', 'HUM-1')`, f.src, uid("w-"))
		return err
	})
	if err == nil || !strings.Contains(err.Error(), "read-only transaction") {
		t.Fatalf("CONTROL: a write inside planRead must be refused as read-only, got %v", err)
	}
}

// TestPlanChannelMoveHoursStops: 5.1a. HUM-77's two rows naming the set
// are not coming to <DST> (Q5) and lie inside an approved sheet (Q8): two
// lines in the spec's words; keeping the member clears only the Q5 line.
func TestPlanChannelMoveHoursStops(t *testing.T) {
	pg := rlsStore(t)
	f := seedMovePlan(t, pg)
	seedMovePlanRows(t, pg, f)
	req := f.req()
	req.noSharedCheck = true // the shared issue is C7's; here only the hours stop
	p := planOf(t, pg, req)
	want := []string{
		"hours: HUM-77 2 rows not coming to " + f.dst + " (Q5)",
		"hours: HUM-77 2 rows inside a frozen or approved sheet (Q8)",
	}
	if got := p.Stops(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("want stops %q, got %q", want, got)
	}
	req.Keep = []string{"HUM-77"}
	if got := planOf(t, pg, req).Stops(); len(got) != 1 || got[0] != want[1] {
		t.Fatalf("a kept member clears only the Q5 line, got %q", got)
	}
}

// TestPlanChannelMoveRefuseTable: a channel with an embed visitor (5.1b)
// refuses through the catalogue's refuse class.
func TestPlanChannelMoveRefuseTable(t *testing.T) {
	pg := rlsStore(t)
	f := seedMovePlan(t, pg)
	if err := seedEmbedVisitor(context.Background(), pg, f.src, f.mv); err != nil {
		t.Fatal(err)
	}
	if p := planOf(t, pg, f.req()); !hasShared(p, "table", "embed_visitors") {
		t.Fatalf("an embed visitor must refuse the move, got %+v", p.Shared)
	}
}
