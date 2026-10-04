package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// flowInsertCTE is the flow write of insertMessageSQL (spec 062 4.2): CTEs
// of the statement that stores the message, so a send pays no extra round
// trip. They write only when `ins` stored the row (never on a resend), and
// read flow_watches as of the statement's snapshot, so the watches this line
// adds take effect from the next line. Parameters: the insert's ($1 tenant,
// $2 msg_id, $3 task_id, $4 channel, $9 to_id, $16 received_at, $17
// expires_at) and four of its own from $n: the author seat ("" = an agent),
// the human seats mentioned, the task a poke DM links to (NULL = not a
// poke) and whether the channel is public.
//
// Ranks are flowKinds: 1 mention, 2 poke, 3 dm, 4 reply. A channel line
// goes to the mentioned seats and its `to` (1) and the thread's watchers
// (4), behind the channel's read door; a DM goes to its `to` only (1 when
// it mentions them, 2 when it is a poke, else 3). A poke whose `to` has a
// mention in the linked task folds into it: no row.
func flowInsertCTE(n int) string {
	a, ms, pk, pub := fmt.Sprintf("$%d::text", n), fmt.Sprintf("$%d::text[]", n+1), fmt.Sprintf("$%d::uuid", n+2), fmt.Sprintf("$%d::bool", n+3)
	return `,
	flow_cand AS (
		SELECT c.member_id, min(c.rnk) AS rnk FROM (
			SELECT unnest(` + ms + `) AS member_id, 1 AS rnk WHERE $4::text IS NOT NULL
			UNION ALL SELECT $9::text, 1 WHERE $4::text IS NOT NULL
			UNION ALL SELECT $9::text, CASE WHEN $9::text = ANY(` + ms + `) THEN 1 WHEN ` + pk + ` IS NOT NULL THEN 2 ELSE 3 END WHERE $4::text IS NULL
			UNION ALL SELECT w.member_id, 4 FROM flow_watches w WHERE w.tenant_id = $1 AND w.task_id = $3 AND $4::text IS NOT NULL
		) c
		WHERE c.member_id ~ '^(HUM|GST)-[0-9]+$' AND c.member_id <> ` + a + `
		  AND ($4::text IS NULL OR ` + pub + ` OR (
			EXISTS (SELECT 1 FROM channel_humans h WHERE h.tenant_id = $1 AND h.channel_id = $4 AND h.human_id = c.member_id)
			AND NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = $1 AND dc.channel_id = $4 AND dc.archived_at IS NOT NULL)))
		GROUP BY c.member_id),
	flow_w AS (INSERT INTO flow_watches (tenant_id, task_id, member_id, since)
		SELECT $1, $3, x.member_id, $16 FROM (SELECT ` + a + ` AS member_id WHERE ` + a + ` <> '' UNION SELECT member_id FROM flow_cand WHERE rnk < 4) x
		WHERE EXISTS (SELECT 1 FROM ins)
		ON CONFLICT DO NOTHING),
	flow_e AS (INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
		SELECT $1, f.member_id, $2, $3, (ARRAY['mention', 'poke', 'dm', 'reply'])[f.rnk], $16, $17 FROM flow_cand f
		WHERE EXISTS (SELECT 1 FROM ins) AND NOT (f.rnk = 2 AND EXISTS (SELECT 1 FROM flow_events x
			WHERE x.tenant_id = $1 AND x.member_id = f.member_id AND x.task_id = ` + pk + ` AND x.kind = 'mention'))
		ON CONFLICT DO NOTHING)`
}

// flowInsertArgs are flowInsertCTE's four parameters for m.
func flowInsertArgs(m Message) []any {
	t := flowTargetsOf(m)
	var poke any
	if t.poke != "" {
		poke = t.poke
	}
	return []any{t.author, t.mentions, poke, t.public}
}

// flowDoorSQL is the read door on event e of message m for e's member:
// a DM by its two ends, a created channel by its (unarchived) member list,
// a public channel ($pub text[]) for every member.
func flowDoorSQL(e, m, pub string) string {
	return ` AND CASE WHEN ` + m + `.channel IS NULL THEN ` + e + `.member_id IN (` + m + `.to_id, ` + m + `.from_id)
		WHEN ` + m + `.channel = ANY(` + pub + `) THEN true
		ELSE EXISTS (SELECT 1 FROM channel_humans h WHERE h.tenant_id = ` + e + `.tenant_id AND h.channel_id = ` + m + `.channel AND h.human_id = ` + e + `.member_id)
			AND NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = ` + e + `.tenant_id AND dc.channel_id = ` + m + `.channel AND dc.archived_at IS NOT NULL) END`
}

// flowCoveredSQL: a mark covers event e of message m (contract section 3):
// f:<msg_id>, or the thread / channel / DM-peer mark at or past the line.
// Each is a read_marks primary-key probe. An archived topic's line is read
// too (owner, t1 56b8cc17: "anything that is archived should not be part of
// the unread messages counter"), by the lists' own archive rule; lobby is a
// bound text $n.
func flowCoveredSQL(e, m, lobby string) string {
	return `(NOT (true` + archivedHideSQL(m, e+`.tenant_id`, lobby) + `) OR EXISTS (SELECT 1 FROM read_marks r WHERE r.tenant_id = ` + e + `.tenant_id AND r.member_id = ` + e + `.member_id AND r.mark_key = 'f:' || ` + e + `.msg_id::text)
		OR EXISTS (SELECT 1 FROM read_marks r WHERE r.tenant_id = ` + e + `.tenant_id AND r.member_id = ` + e + `.member_id
			AND r.mark_key IN ('t:' || ` + m + `.task_id::text,
				CASE WHEN ` + m + `.channel IS NULL THEN 'dm:' || ` + m + `.from_id ELSE 'ch:' || ` + m + `.channel END,
				CASE WHEN ` + m + `.channel IS NULL THEN 'dm:' || ` + m + `.from_id || '@' || ` + m + `.from_box END)
			AND (` + m + `.received_at, ` + m + `.msg_id::text) <= (r.at, r.msg_id)))`
}

// flowCountsSQL selects the ten counts (badge mention/reply/dm/channels/dms,
// then the same unread) of member in tenant at now, and the unread per
// sidebar row as a jsonb object (FlowKeys: flowPlaceKey and t:<task_id>):
// one scan of the member's flow_events_member_at range.
func flowCountsSQL(tenant, member, now, pub, lobby string) string {
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

// flowEventCols are the FlowEvent columns of event e / message m, scanned
// by scanFlowEvent.
func flowEventCols(e, m, lobby string) string {
	return e + `.msg_id::text, ` + m + `.task_id::text, coalesce(` + m + `.parent_task_id::text, ''), coalesce(` + m + `.channel, ''),
		` + m + `.from_id, ` + m + `.from_box, coalesce(` + m + `.to_id, ''), coalesce(` + m + `.to_box, ''), coalesce(` + m + `.typed_by, ''),
		` + e + `.kind, left(` + m + `.body, 400), CASE WHEN jsonb_typeof(` + m + `.files) = 'array' THEN jsonb_array_length(` + m + `.files) ELSE 0 END,
		` + m + `.received_at, NOT ` + flowCoveredSQL(e, m, lobby)
}

func scanFlowEvent(r pgx.Rows, extra ...any) (FlowEvent, error) {
	var ev FlowEvent
	dest := append([]any{&ev.MsgID, &ev.TaskID, &ev.ParentTaskID, &ev.Channel, &ev.FromID, &ev.FromBox, &ev.ToID, &ev.ToBox,
		&ev.TypedBy, &ev.Kind, &ev.Body, &ev.Files, &ev.At, &ev.Unread}, extra...)
	return ev, r.Scan(dest...)
}

func scanFlowCounts(r pgx.Rows, extra ...any) (c, u FlowCounts, keys map[string]int, err error) {
	err = r.Scan(append(append([]any{}, extra...), flowCountsDest(&c, &u, &keys)...)...)
	c.Total, u.Total = c.Mention+c.Reply+c.DM, u.Mention+u.Reply+u.DM
	return c, u, keys, err
}

// flowCountsDest are the scan targets of flowCountsSQL's columns, in order.
func flowCountsDest(c, u *FlowCounts, keys *map[string]int) []any {
	return []any{&c.Mention, &c.Reply, &c.DM, &c.Channels, &c.DMs, &u.Mention, &u.Reply, &u.DM, &u.Channels, &u.DMs, keys}
}

// flowKindsFilter is the kind= filter as kind values (nil = all).
func flowKindsFilter(kind string) []string {
	switch kind {
	case "":
		return nil
	case FlowMention:
		return []string{FlowMention, FlowPoke}
	}
	return []string{kind}
}

func (s *Postgres) FlowRead(ctx context.Context, q FlowQuery) (FlowPage, error) {
	var p FlowPage
	reads := []tenantRead{{
		sql:  flowCountsSQL("$1", "$2", "$3", "$4::text[]", "$5::text"),
		args: []any{q.Tenant, q.Member, q.Now, PublicChannels, q.Lobby},
		each: func(r pgx.Rows) (err error) { p.Counts, p.Unread, p.Keys, err = scanFlowCounts(r); return err },
	}}
	if q.Limit > 0 {
		var before, beforeID any
		if q.BeforeID != "" {
			before, beforeID = q.BeforeAt, q.BeforeID
		}
		limit := min(q.Limit, FlowMaxPage)
		reads = append(reads, tenantRead{
			sql: `SELECT ` + flowEventCols("e", "m", "$9::text") + `
				FROM flow_events e JOIN messages m ON m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id
				WHERE e.tenant_id = $1 AND e.member_id = $2 AND e.expires_at > $3 AND m.expires_at > $3` + flowDoorSQL("e", "m", "$4::text[]") + `
				  AND ($6::timestamptz IS NULL OR (e.at, e.msg_id) < ($6::timestamptz, $7::uuid))
				  AND ($8::text[] IS NULL OR e.kind = ANY($8::text[]))
				ORDER BY e.at DESC, e.msg_id DESC LIMIT $5`,
			args: []any{q.Tenant, q.Member, q.Now, PublicChannels, limit + 1, before, beforeID, flowKindsFilter(q.Kind), q.Lobby},
			each: func(r pgx.Rows) error {
				ev, err := scanFlowEvent(r)
				if err != nil {
					return err
				}
				if len(p.Events) == limit {
					p.More = true
					return nil
				}
				p.Events = append(p.Events, ev)
				return nil
			},
		})
	}
	return p, s.queryTenantBatch(ctx, q.Tenant, reads...)
}

func (s *Postgres) FlowFanout(ctx context.Context, tenant, msgID string, members []string, now time.Time, lobby string) (map[string]FlowPush, error) {
	out := map[string]FlowPush{}
	if len(members) == 0 {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, `SELECT `+flowEventCols("e", "m", "$6::text")+`, e.member_id, c.*
		FROM flow_events e JOIN messages m ON m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id
		CROSS JOIN LATERAL (`+flowCountsSQL("e.tenant_id", "e.member_id", "$4", "$5::text[]", "$6::text")+`) c
		WHERE e.tenant_id = $1 AND e.msg_id = $2 AND e.member_id = ANY($3) AND e.expires_at > $4`+flowDoorSQL("e", "m", "$5::text[]"),
		[]any{tenant, msgID, members, now, PublicChannels, lobby}, func(r pgx.Rows) error {
			var member string
			var c, u FlowCounts
			var keys map[string]int
			ev, err := scanFlowEvent(r, append([]any{&member}, flowCountsDest(&c, &u, &keys)...)...)
			if err != nil {
				return err
			}
			c.Total, u.Total = c.Mention+c.Reply+c.DM, u.Mention+u.Reply+u.DM
			out[member] = FlowPush{Event: ev, Counts: c, Unread: u, Keys: keys}
			return nil
		})
	return out, err
}

// flowMarkSweepSQL deletes the f:<msg_id> marks whose message is gone
// ($1 now, $2 the chunk): the Flow's per-entry read state goes with its
// line, as flow_events do by FK. The msg_id is computed in r BEFORE the
// anti-join (perf 20261004 E01): under RLS a CASE/regex/cast inside NOT
// EXISTS is not leakproof, so it could not be an index condition and every
// mark filtered the tenant's whole messages table; r.msg_id is a plain column,
// one messages_pkey probe per mark. A non-uuid key stays NULL, matches nothing
// and is deleted as before. gone is materialized once, so the DELETE does not
// re-run the anti-join per read_marks row.
const flowMarkSweepSQL = `WITH r AS MATERIALIZED (
		SELECT tenant_id, member_id, mark_key,
			CASE WHEN substr(mark_key, 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
				THEN substr(mark_key, 3)::uuid END AS msg_id
		FROM read_marks WHERE mark_key LIKE 'f:%' AND mark_key <> 'f:seen' AND updated_at <= $1),
	gone AS MATERIALIZED (SELECT r.tenant_id, r.member_id, r.mark_key FROM r
		WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = r.tenant_id AND m.msg_id = r.msg_id)
		LIMIT $2)
	DELETE FROM read_marks d USING gone g
	WHERE d.tenant_id = g.tenant_id AND d.member_id = g.member_id AND d.mark_key = g.mark_key`
