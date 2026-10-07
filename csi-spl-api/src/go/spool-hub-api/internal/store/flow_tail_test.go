package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// flowCountsOracleSQL is flowCountsSQL before api perf ap-01b: every event
// of the member joined to its message and checked against the marks. It is
// the oracle the tail read must equal, byte for byte of its result.
func flowCountsOracleSQL(tenant, member, now, pub, lobby string) string {
	return `WITH fc AS (SELECT fe.kind, fm.channel IS NOT NULL AS in_ch,
				CASE WHEN fm.channel IS NOT NULL THEN 'ch:' || fm.channel
					WHEN coalesce(fm.from_box, '') <> '' THEN 'dm:' || fm.from_id || '@' || fm.from_box
					ELSE 'dm:' || fm.from_id END AS place_key,
				't:' || fm.task_id::text AS topic_key,
				fe.at > coalesce((SELECT s.at FROM read_marks s
				WHERE s.tenant_id = ` + tenant + ` AND s.member_id = ` + member + ` AND s.mark_key = 'f:seen'), '-infinity'::timestamptz) AS unseen
			FROM flow_events fe JOIN messages fm ON fm.tenant_id = fe.tenant_id AND fm.msg_id = fe.msg_id
			WHERE fe.tenant_id = ` + tenant + ` AND fe.member_id = ` + member + ` AND fe.expires_at > ` + now + ` AND fm.expires_at > ` + now +
		flowDoorSQL("fe", "fm", pub) + ` AND NOT ` + flowCoveredSQL("fe", "fm", lobby) + `)
		SELECT count(*) FILTER (WHERE fc.unseen AND fc.kind IN ('mention', 'poke')),
			count(*) FILTER (WHERE fc.unseen AND fc.kind = 'reply'),
			count(*) FILTER (WHERE fc.unseen AND fc.kind = 'dm'),
			count(*) FILTER (WHERE fc.unseen AND fc.in_ch),
			count(*) FILTER (WHERE fc.unseen AND NOT fc.in_ch),
			count(*) FILTER (WHERE fc.kind IN ('mention', 'poke')),
			count(*) FILTER (WHERE fc.kind = 'reply'),
			count(*) FILTER (WHERE fc.kind = 'dm'),
			count(*) FILTER (WHERE fc.in_ch),
			count(*) FILTER (WHERE NOT fc.in_ch),
			(SELECT coalesce(jsonb_object_agg(k.key, k.n), '{}'::jsonb) FROM (SELECT x.key, count(*) AS n
				FROM fc f2 CROSS JOIN LATERAL (VALUES (f2.place_key), (f2.topic_key)) x(key) GROUP BY x.key) k)
		FROM fc`
}

// API perf ap-01b: the Flow counts read only the events past each place's
// read mark, and equal the old full read at every step: a channel mark that
// ties two lines on received_at, a DM mark by peer covering two of its
// boxes, a by-box DM mark, the box-less DM's degenerate dm:<from>@ mark, a
// topic and an f: mark, f:seen, an archived topic, an expired line and an
// event whose keys are not stored. FlowRead and FlowFanout give the new
// counts.
func TestFlowCountsTailEqualsOracle(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	base := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	lobby := uuid4()
	now := base.Add(time.Hour)
	n := 0
	post := func(at time.Time, from, fromBox, to, channel, task, body string) Message {
		t.Helper()
		m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
		m.FromID, m.FromBox, m.ToID, m.Channel, m.Body = from, fromBox, to, channel, body
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	next := func() time.Time { n++; return base.Add(time.Duration(n) * time.Second) }
	members := []string{"HUM-1", "HUM-2"}
	result := func(sql, member string) (string, int) {
		t.Helper()
		var sum string
		var unread int
		err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT md5(row(q.*)::text), q.um + q.ur + q.ud FROM (`+
				sql+`) q(cm, cr, cd, cc, cdm, um, ur, ud, uc, udm, keys)`,
				tid, member, now, PublicChannels, lobby).Scan(&sum, &unread)
		})
		if err != nil {
			t.Fatal(err)
		}
		return sum, unread
	}
	check := func(step string, wantUnread int) {
		t.Helper()
		for _, mem := range members {
			got, u := result(flowCountsSQL("$1", "$2", "$3", "$4::text[]", "$5::text"), mem)
			want, _ := result(flowCountsOracleSQL("$1", "$2", "$3", "$4::text[]", "$5::text"), mem)
			if got != want {
				t.Fatalf("%s: %s tail md5 %s, oracle %s", step, mem, got, want)
			}
			if mem == "HUM-1" && u != wantUnread {
				t.Fatalf("%s: HUM-1 unread %d, want %d", step, u, wantUnread)
			}
		}
	}
	mark := func(member string, marks map[string]ReadMark) {
		t.Helper()
		if err := pg.SaveReadMarks(ctx, tid, member, marks, now); err != nil {
			t.Fatal(err)
		}
	}

	T, U := uuid4(), uuid4()
	tie := next()
	a := post(tie, "HUM-2", "box-wui", "", "lobby", T, "@HUM-1 card")
	b := post(tie, "c-034", "box-a", "", "lobby", T, "@HUM-1 @HUM-2 same instant")
	lo, hi := a, b
	if lo.MsgID > hi.MsgID {
		lo, hi = hi, lo
	}
	r := post(next(), "c-034", "box-a", "", "lobby", T, "@HUM-1 later")
	post(next(), "HUM-3", "box-wui", "", "feedback", U, "@HUM-1 @HUM-2 other")
	f := post(next(), "HUM-3", "box-wui", "", "feedback", U, "@HUM-1 more")
	da := post(next(), "c-034", "box-a", "HUM-1", "", uuid4(), "dm box a")
	db := post(next(), "c-034", "box-b", "HUM-1", "", uuid4(), "dm box b")
	post(next(), "c-034", "box-a", "HUM-1", "", uuid4(), "dm box a again")
	dh := post(next(), "HUM-2", "", "HUM-1", "", uuid4(), "dm with no box")
	gone := post(next(), "HUM-2", "", "HUM-1", "", uuid4(), "dm that expires")
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET expires_at = $3 WHERE tenant_id = $1 AND msg_id = $2::uuid`, tid, gone.MsgID, now.Add(-time.Second))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	check("no marks", 9)

	mark("HUM-1", map[string]ReadMark{"ch:lobby": {At: tie, MsgID: lo.MsgID}})
	mark("HUM-2", map[string]ReadMark{"ch:lobby": {At: tie, MsgID: hi.MsgID}})
	check("lobby mark on the tie", 8)

	mark("HUM-1", map[string]ReadMark{"dm:c-034": {At: db.ReceivedAt, MsgID: db.MsgID}})
	check("dm mark by peer", 6)

	mark("HUM-1", map[string]ReadMark{"dm:c-034@box-a": {At: base.Add(time.Hour), MsgID: ""}, "dm:HUM-2@": {At: dh.ReceivedAt, MsgID: dh.MsgID}})
	check("dm marks by box", 4)

	mark("HUM-1", map[string]ReadMark{ThreadMarkKey(U): {At: f.ReceivedAt.Add(-time.Millisecond), MsgID: ""}, FlowMarkKey(r.MsgID): {At: now, MsgID: r.MsgID},
		FlowSeenKey: {At: da.ReceivedAt, MsgID: da.MsgID}})
	check("topic, f: and f:seen marks", 2)

	// keys not stored (an event written around the migration): always in the tail.
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE flow_events SET place_key = NULL WHERE tenant_id = $1 AND msg_id = $2::uuid`, tid, hi.MsgID)
		if err == nil {
			_, err = tx.Exec(ctx, `UPDATE flow_events SET cov_at = NULL WHERE tenant_id = $1 AND msg_id = $2::uuid`, tid, f.MsgID)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	check("keys not stored", 2)

	if _, err := pg.SetArchived(ctx, tid, f.MsgID, "HUM-3", now.Add(-time.Minute), true); err != nil {
		t.Fatal(err)
	}
	check("archived", 1)

	p, err := pg.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now, Lobby: lobby})
	if err != nil {
		t.Fatal(err)
	}
	push, err := pg.FlowFanout(ctx, tid, hi.MsgID, members, now, lobby)
	if err != nil {
		t.Fatal(err)
	}
	if p.Unread.Total != 1 || push["HUM-1"].Unread != p.Unread || push["HUM-1"].Counts != p.Counts {
		t.Fatalf("FlowRead unread %+v counts %+v, FlowFanout %+v", p.Unread, p.Counts, push["HUM-1"])
	}
}

// flowLateralEdits are the three query-shape edits of the ap-01b follow-up,
// each as {the a8e3723 text, the served text}: the per-place tail as a
// LATERAL with OFFSET 0, the coalesce inside the place mark, and the message
// as a LATERAL primary-key probe.
var flowLateralEdits = [][2]string{
	{`ft AS (SELECT fe.tenant_id, fe.member_id, fe.msg_id, fe.kind, fe.at, fe.expires_at FROM fp`, `ft AS (SELECT fe.* FROM fp`},
	{`SELECT max(r.at) AS at FROM read_marks r`, `SELECT coalesce(max(r.at), '-infinity'::timestamptz) AS at FROM read_marks r`},
	{`JOIN flow_events fe ON fe.tenant_id = $1 AND fe.member_id = $2 AND fe.place_key = fp.k
				AND fe.cov_at >= coalesce(fb.at, '-infinity'::timestamptz)`, `CROSS JOIN LATERAL (SELECT fe.tenant_id, fe.member_id, fe.msg_id, fe.kind, fe.at, fe.expires_at FROM flow_events fe
				WHERE fe.tenant_id = $1 AND fe.member_id = $2 AND fe.place_key = fp.k
				AND fe.cov_at >= fb.at OFFSET 0) fe`},
	{`FROM ft fe JOIN messages fm ON fm.tenant_id = fe.tenant_id AND fm.msg_id = fe.msg_id`, `FROM ft fe CROSS JOIN LATERAL (SELECT fm.channel, fm.from_box, fm.from_id, fm.to_id, fm.task_id, fm.parent_task_id, fm.msg_id, fm.received_at, fm.expires_at FROM messages fm WHERE fm.tenant_id = fe.tenant_id AND fm.msg_id = fe.msg_id LIMIT 1) fm`},
}

// flowCountsTailV1 is the a8e3723 statement (the one the LATERAL shape
// replaced), rebuilt from the served text by undoing each edit. An edit the
// served text no longer carries fails the test.
func flowCountsTailV1(t *testing.T, served string) string {
	t.Helper()
	for _, e := range flowLateralEdits {
		if strings.Count(served, e[1]) != 1 {
			t.Fatalf("served flowCountsSQL lost a LATERAL edit: %q", e[1])
		}
		served = strings.Replace(served, e[1], e[0], 1)
	}
	return served
}

// API perf ap-01b follow-up: the LATERAL shape of flowCountsSQL returns the
// same row as the a8e3723 statement and the full-read oracle, under the
// tenant's RLS scope, over several places: a channel marked part way, one
// marked to the end, one place with NO mark (fb is '-infinity', not NULL),
// a DM marked by peer and a box-less DM. Control: the served text with the
// coalesce taken back out of the mark (cov_at >= NULL) loses the unmarked
// place, and the fixture sees it.
func TestFlowCountsLateralEqualsTail(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	base := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	lobby := uuid4()
	now := base.Add(time.Hour)
	n := 0
	post := func(from, fromBox, to, channel, task, body string) Message {
		t.Helper()
		n++
		at := base.Add(time.Duration(n) * time.Second)
		m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
		m.FromID, m.FromBox, m.ToID, m.Channel, m.Body = from, fromBox, to, channel, body
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	result := func(sql, member string) (string, int) {
		t.Helper()
		var sum string
		var unread int
		err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT md5(row(q.*)::text), q.um + q.ur + q.ud FROM (`+
				sql+`) q(cm, cr, cd, cc, cdm, um, ur, ud, uc, udm, keys)`,
				tid, member, now, PublicChannels, lobby).Scan(&sum, &unread)
		})
		if err != nil {
			t.Fatal(err)
		}
		return sum, unread
	}
	served := flowCountsSQL("$1", "$2", "$3", "$4::text[]", "$5::text")
	v1 := flowCountsTailV1(t, served)
	broken := strings.Replace(served, flowLateralEdits[1][1], flowLateralEdits[1][0], 1)
	check := func(step string, wantUnread int) {
		t.Helper()
		for _, mem := range []string{"HUM-1", "HUM-2"} {
			got, u := result(served, mem)
			old, _ := result(v1, mem)
			want, _ := result(flowCountsOracleSQL("$1", "$2", "$3", "$4::text[]", "$5::text"), mem)
			if got != old || got != want {
				t.Fatalf("%s: %s served md5 %s, a8e3723 %s, oracle %s", step, mem, got, old, want)
			}
			if mem == "HUM-1" && u != wantUnread {
				t.Fatalf("%s: HUM-1 unread %d, want %d", step, u, wantUnread)
			}
		}
		ctl, _ := result(broken, "HUM-1")
		if old, _ := result(v1, "HUM-1"); ctl == old {
			t.Fatalf("%s: control: the mark without its coalesce gave the same row; the fixture has no unmarked place", step)
		}
	}

	TL, TF, TK := uuid4(), uuid4(), uuid4()
	post("c-034", "box-a", "", "lobby", TL, "@HUM-1 l1")
	l2 := post("c-034", "box-a", "", "lobby", TL, "@HUM-1 @HUM-2 l2")
	post("c-034", "box-a", "", "lobby", TL, "@HUM-1 l3")
	post("HUM-3", "box-wui", "", "feedback", TF, "@HUM-1 f1")
	f2 := post("HUM-3", "box-wui", "", "feedback", TF, "@HUM-1 @HUM-2 f2")
	post("HUM-3", "box-wui", "", "tasks", TK, "@HUM-1 k1 (no mark ever)")
	post("HUM-3", "box-wui", "", "tasks", TK, "@HUM-1 @HUM-2 k2 (no mark ever)")
	d1 := post("c-034", "box-a", "HUM-1", "", uuid4(), "d1")
	post("c-034", "box-a", "HUM-1", "", uuid4(), "d2")
	post("HUM-2", "", "HUM-1", "", uuid4(), "h1")
	check("no marks", 10)

	if err := pg.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{
		"ch:lobby": {At: l2.ReceivedAt, MsgID: l2.MsgID}, "ch:feedback": {At: f2.ReceivedAt, MsgID: f2.MsgID},
		"dm:c-034": {At: d1.ReceivedAt, MsgID: d1.MsgID},
	}, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.SaveReadMarks(ctx, tid, "HUM-2", map[string]ReadMark{"ch:lobby": {At: now, MsgID: ""}}, now); err != nil {
		t.Fatal(err)
	}
	check("marks on all but tasks and the box-less dm", 5)
}
