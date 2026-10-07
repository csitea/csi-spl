package store

import (
	"context"
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
