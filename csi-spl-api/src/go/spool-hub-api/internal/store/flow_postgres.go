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
// adds take effect from the next line. Each event stores its place_key and
// cov_at (rdb 0137: spool_flow_place_key, the line's received_at), which the
// messages trigger keeps current on a move or merge. Parameters: the
// insert's ($1 tenant, $2 msg_id, $3 task_id, $4 channel, $6 from_box, $7
// from_id, $16 received_at, $17 expires_at) and seven of its own from $n
// (flowInsertArgs): the author seat ("" = an agent), the members mentioned,
// the task a poke DM links to (NULL = not a poke), whether the channel is
// public, the `to` as a member key, the agent author as <id>@<box> and the
// line kind (NULL = each member's rank).
//
// Ranks are flowKinds: 1 mention, 2 poke, 3 dm, 4 reply. A channel line
// goes to the mentioned members and its `to` (1) and the thread's watchers
// (4), behind the channel's read door; a DM goes to its `to` only (1 when
// it mentions them, 2 when it is a poke, else 3). A poke whose `to` has a
// mention in the linked task folds into it: no row. A blocker line and a
// line that carries `accepts` label every event blocked / ready (spec 130
// section 4). An agent (<id>@<box>, spec 130 section 5) takes rank 1 of a
// channel line, behind its channel_subscriptions door, and a DM to it that
// carries accepts (`ready`), and never watches: its inbox already delivers
// DMs and replies.
func flowInsertCTE(n int) string {
	p := func(i int, typ string) string { return fmt.Sprintf("$%d::%s", n+i, typ) }
	a, ms, pk, pub := p(0, "text"), p(1, "text[]"), p(2, "uuid"), p(3, "bool")
	to, snd, lbl := p(4, "text"), p(5, "text"), p(6, "text")
	agent := `c.member_id ` + flowAgentSQL
	return `,
	flow_cand AS (
		SELECT c.member_id, min(c.rnk) AS rnk FROM (
			SELECT unnest(` + ms + `) AS member_id, 1 AS rnk WHERE $4::text IS NOT NULL
			UNION ALL SELECT ` + to + `, 1 WHERE $4::text IS NOT NULL
			UNION ALL SELECT ` + to + `, CASE WHEN ` + to + ` = ANY(` + ms + `) THEN 1 WHEN ` + pk + ` IS NOT NULL THEN 2 ELSE 3 END WHERE $4::text IS NULL
			UNION ALL SELECT w.member_id, 4 FROM flow_watches w WHERE w.tenant_id = $1 AND w.task_id = $3 AND $4::text IS NOT NULL
		) c
		WHERE c.member_id <> ` + a + ` AND c.member_id <> ` + snd + ` AND (c.member_id ~ '^(HUM|GST)-[0-9]+$'
			OR (c.rnk = 1 AND $4::text IS NOT NULL OR $4::text IS NULL AND ` + lbl + ` = 'ready') AND ` + agent + `)
		  AND ($4::text IS NULL OR ` + pub + ` OR (
			(EXISTS (SELECT 1 FROM channel_humans h WHERE h.tenant_id = $1 AND h.channel_id = $4 AND h.human_id = c.member_id)
				OR EXISTS (SELECT 1 FROM channel_subscriptions cs WHERE cs.tenant_id = $1 AND cs.channel_id = $4
					AND cs.agent_id = split_part(c.member_id, '@', 1) AND cs.box_id = split_part(c.member_id, '@', 2) AND cs.origin <> 'removed'))
			AND NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = $1 AND dc.channel_id = $4 AND dc.archived_at IS NOT NULL)))
		GROUP BY c.member_id),
	flow_w AS (INSERT INTO flow_watches (tenant_id, task_id, member_id, since)
		SELECT $1, $3, x.member_id, $16 FROM (SELECT ` + a + ` AS member_id WHERE ` + a + ` <> ''
			UNION SELECT member_id FROM flow_cand WHERE rnk < 4 AND member_id ~ '^(HUM|GST)-[0-9]+$') x
		WHERE EXISTS (SELECT 1 FROM ins)
		ON CONFLICT DO NOTHING),
	flow_e AS (INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at, place_key, cov_at)
		SELECT $1, f.member_id, $2, $3, coalesce(` + lbl + `, (ARRAY['mention', 'poke', 'dm', 'reply'])[f.rnk]), $16, $17,
			spool_flow_place_key($4::text, $7::text, $6::text), $16 FROM flow_cand f
		WHERE EXISTS (SELECT 1 FROM ins) AND NOT (f.rnk = 2 AND EXISTS (SELECT 1 FROM flow_events x
			WHERE x.tenant_id = $1 AND x.member_id = f.member_id AND x.task_id = ` + pk + ` AND x.kind = 'mention'))
		ON CONFLICT DO NOTHING)`
}

// flowInsertArgs are flowInsertCTE's seven parameters for m.
func flowInsertArgs(m Message) []any {
	t := flowTargetsOf(m)
	var poke, label any
	if t.poke != "" {
		poke = t.poke
	}
	if t.label != "" {
		label = t.label
	}
	return []any{t.author, t.mentions, poke, t.public, t.to, t.sender, label}
}

// flowDoorSQL is the read door on event e of message m for e's member:
// a DM by its two ends (an agent end as <id>@<box>), a created channel by its (unarchived) member list
// (an agent <id>@<box> by its channel_subscriptions row), a public channel
// ($pub text[]) for every member.
func flowDoorSQL(e, m, pub string) string {
	return ` AND CASE WHEN ` + m + `.channel IS NULL THEN ` + e + `.member_id IN (` + m + `.to_id, ` + m + `.from_id,
			` + m + `.to_id || '@' || ` + m + `.to_box, ` + m + `.from_id || '@' || ` + m + `.from_box)
		WHEN ` + m + `.channel = ANY(` + pub + `) THEN true
		ELSE (EXISTS (SELECT 1 FROM channel_humans h WHERE h.tenant_id = ` + e + `.tenant_id AND h.channel_id = ` + m + `.channel AND h.human_id = ` + e + `.member_id)
				OR EXISTS (SELECT 1 FROM channel_subscriptions cs WHERE cs.tenant_id = ` + e + `.tenant_id AND cs.channel_id = ` + m + `.channel
					AND cs.agent_id = split_part(` + e + `.member_id, '@', 1) AND cs.box_id = split_part(` + e + `.member_id, '@', 2) AND cs.origin <> 'removed'))
			AND NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = ` + e + `.tenant_id AND dc.channel_id = ` + m + `.channel AND dc.archived_at IS NOT NULL) END`
}

// flowCoveredSQL: a mark covers event e of message m (contract section 3):
// f:<msg_id>, or the thread / channel / DM-peer mark at or past the line.
// Each is a read_marks primary-key probe. An archived topic's line is read
// too (owner, t1 56b8cc17: "anything that is archived should not be part of
// the unread messages counter"), by the lists' own archive rule; lobby is a
// bound text $n.
//
// A ch: mark covers a channel line only while the member has no t: mark for
// its topic (SPL-2124, the CLE-77930 rule): opening a channel moves ch: past
// the replies its cards still count as "<new>/<total>", so the thread mark
// alone decides that topic's lines.
//
// A channel line whose topic has no live card in its channel is read too
// (SPL-2506, owner t1 bd5edeb3: "it shows 3 unread msgs, but ... there are no
// topics with those unread msgs"): the channel lists a topic by its is_parent
// 1 row, and the sweep purges an expired head while later replies live on,
// so their ch: and t: counts had no card to show them on. now is a bound
// timestamptz; the lobby's thread and the issues / tasks boards are left out.
func flowCoveredSQL(e, m, now, lobby string) string {
	mark := `SELECT 1 FROM read_marks r WHERE r.tenant_id = ` + e + `.tenant_id AND r.member_id = ` + e + `.member_id AND r.mark_key = `
	past := ` AND (` + m + `.received_at, ` + m + `.msg_id::text) <= (r.at, r.msg_id)`
	return `(NOT (true` + archivedHideSQL(m, e+`.tenant_id`, lobby) + `) OR EXISTS (` + mark + `'f:' || ` + e + `.msg_id::text)
		OR EXISTS (` + mark + `'t:' || ` + m + `.task_id::text` + past + `)
		OR (` + m + `.channel IS NULL AND EXISTS (SELECT 1 FROM read_marks r WHERE r.tenant_id = ` + e + `.tenant_id AND r.member_id = ` + e + `.member_id
			AND r.mark_key IN ('dm:' || ` + m + `.from_id, 'dm:' || ` + m + `.from_id || '@' || ` + m + `.from_box)` + past + `))
		OR (` + m + `.channel IS NOT NULL AND EXISTS (` + mark + `'ch:' || ` + m + `.channel` + past + `)
			AND NOT EXISTS (` + mark + `'t:' || ` + m + `.task_id::text))` + flowHeadlessSQL(e, m, now, lobby) + `)`
}

// flowHeadlessSQL: OR the channel line's topic (its parent topic for a
// sub-thread line) has no live is_parent 1 row in that channel (SPL-2506).
// The issues and tasks boards are left out: their lines (HUB-0 writes them
// with is_parent 0) are rows of their own pages, not channel cards. One probe
// keyed on (tenant_id, task_id). The topic is a CASE, not coalesce (SPL-2705):
// under row-level security a qual that Postgres cannot prove leakproof stays
// behind the policy quals, a CoalesceExpr never is, so h.task_id = coalesce(..)
// was a Filter and prd read the whole channel on messages_channel per line
// (2026-10-20: 1 959 rows per loop, 85 790 of flow_counts' 94 046 buffers).
// Test: flow_headless_plan_test.go.
func flowHeadlessSQL(e, m, now, lobby string) string {
	topic := `CASE WHEN ` + m + `.parent_task_id IS NULL THEN ` + m + `.task_id ELSE ` + m + `.parent_task_id END`
	return `
		OR (` + m + `.channel IS NOT NULL AND ` + m + `.channel NOT IN ('` + ChannelIssues + `', '` + ChannelTasks + `')
			AND ` + topic + `::text <> ` + lobby + ` AND NOT EXISTS (SELECT 1 FROM messages h
			WHERE h.tenant_id = ` + e + `.tenant_id AND h.task_id = ` + topic + ` AND h.channel = ` + m + `.channel
			AND h.is_parent = 1 AND h.expires_at > ` + now + `))`
}

// flowCountsSQL selects the ten counts (badge mention/reply/dm/channels/dms,
// then the same unread), the release days newer than f:seen (spec 130), of
// member in tenant at now, and the unread per sidebar row as a jsonb object
// (FlowKeys: flowPlaceKey and t:<task_id>).
//
// The counts are flowEventCountsSQL's. The keys are its keys plus
// flowChannelKeysSQL's lines (SPL-2837, bug round 3 row 03): a channel row
// and a topic card count every unread line of the channel, as the channel
// view does, not only the lines that concern the member. The Flow badge
// counts stay the member's events (spec 062, "only what concerns me").
func flowCountsSQL(tenant, member, now, pub, lobby string) string {
	return `SELECT q.cm, q.cr, q.cd, q.cc, q.cdm, q.um, q.ur, q.ud, q.uc, q.udm, q.rel,
			(SELECT coalesce(jsonb_object_agg(k.key, k.n), '{}'::jsonb) FROM (SELECT x.key, sum(x.n)::int AS n FROM (
				SELECT j.key, j.value::int AS n FROM jsonb_each_text(q.keys) j
				UNION ALL SELECT x.key, 1 FROM (` + flowChannelKeysSQL(tenant, member, now, pub, lobby) + `) l
					CROSS JOIN LATERAL (VALUES (l.place_key), (l.topic_key)) x(key)) x GROUP BY x.key) k)
		FROM (` + flowEventCountsSQL(tenant, member, now, pub, lobby) + `) q(cm, cr, cd, cc, cdm, um, ur, ud, uc, udm, rel, keys)`
}

// flowChannelKeysSQL is the unread channel lines of a human member that have
// no flow event of theirs (flowInsertCTE writes one only for a line that
// mentions, addresses or replies to them), as (place_key, topic_key): a new
// topic that names nobody, a reply in a topic they opened but do not watch.
// The lines are found as ViewChannelStats finds them: cl walks the tenant's
// channels (one probe each) and keeps the ones behind the member's read door
// (flowDoorSQL's channel arms, once per channel), each read past the member's
// ch: mark on messages_channel (every line when there is none); then the t:
// marked topics' lines at or past the thread mark and before the channel's
// mark (flowThreadTailSQL's complement, so no line is read twice).
//
// lc keeps a line that is not the member's own (from_id, typed_by), has no
// flow event and is past its t: mark when there is one, behind OFFSET 0: each
// is one primary-key probe, and on prd t1 (HUM-10) they drop all but a few of
// the ~2 400 lines read, so the rest of the rules (flowCoveredSQL: f:, ch:,
// archived, headless; the door again) probe those few, not a hash of the
// tenant's messages. The t: test is flowCoveredSQL's own arm, so the result
// is the same. The issues and tasks boards are not channels (ChannelHidden).
func flowChannelKeysSQL(tenant, member, now, pub, lobby string) string {
	cols := `x.msg_id, x.channel, x.task_id, x.parent_task_id, x.from_id, x.from_box, x.to_id, x.to_box, x.typed_by, x.received_at`
	shown := ` NOT IN ('` + ChannelIssues + `', '` + ChannelTasks + `')`
	human := member + `::text ~ '^(HUM|GST)-[0-9]+$'`
	return `SELECT 'ch:' || lc.channel AS place_key, 't:' || lc.task_id::text AS topic_key FROM (SELECT lx.* FROM (
			WITH RECURSIVE cl(ch) AS (SELECT (SELECT min(y.channel) FROM messages y WHERE y.tenant_id = ` + tenant + ` AND y.channel IS NOT NULL) WHERE ` + human + `
				UNION ALL SELECT (SELECT min(y.channel) FROM messages y WHERE y.tenant_id = ` + tenant + ` AND y.channel > cl.ch) FROM cl WHERE cl.ch IS NOT NULL)
			SELECT ` + cols + ` FROM cl
				CROSS JOIN LATERAL (SELECT coalesce(max(r.at), '-infinity'::timestamptz) AS at FROM read_marks r
					WHERE r.tenant_id = ` + tenant + ` AND r.member_id = ` + member + ` AND r.mark_key = 'ch:' || cl.ch) cb
				CROSS JOIN LATERAL (SELECT ` + cols + ` FROM messages x WHERE x.tenant_id = ` + tenant + ` AND x.channel = cl.ch
					AND x.received_at >= cb.at AND x.expires_at > ` + now + ` OFFSET 0) x
				WHERE cl.ch IS NOT NULL AND cl.ch` + shown + ` AND (cl.ch = ANY(` + pub + `)
					OR EXISTS (SELECT 1 FROM channel_humans h WHERE h.tenant_id = ` + tenant + ` AND h.channel_id = cl.ch AND h.human_id = ` + member + `)
					AND NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = ` + tenant + ` AND dc.channel_id = cl.ch AND dc.archived_at IS NOT NULL))
			UNION ALL SELECT ` + cols + ` FROM ` + threadMarksSQL(tenant, member, lobby) + `
				CROSS JOIN LATERAL (SELECT ` + cols + ` FROM messages x WHERE x.tenant_id = ` + tenant + ` AND x.task_id = k.task
					AND x.received_at >= tm.at AND x.channel IS NOT NULL AND x.expires_at > ` + now + ` OFFSET 0) x
				WHERE ` + human + ` AND x.channel` + shown + ` AND x.received_at < (SELECT max(r.at) FROM read_marks r
					WHERE r.tenant_id = ` + tenant + ` AND r.member_id = ` + member + ` AND r.mark_key = 'ch:' || x.channel)) lx
			WHERE lx.from_id IS DISTINCT FROM ` + member + ` AND lx.typed_by IS DISTINCT FROM ` + member + `
				AND (SELECT true FROM flow_events f WHERE f.tenant_id = ` + tenant + ` AND f.member_id = ` + member + ` AND f.msg_id = lx.msg_id) IS NULL
				AND (SELECT true FROM read_marks r WHERE r.tenant_id = ` + tenant + ` AND r.member_id = ` + member + `
					AND r.mark_key = 't:' || lx.task_id::text AND (lx.received_at, lx.msg_id::text) <= (r.at, r.msg_id)) IS NULL
			OFFSET 0) lc
		CROSS JOIN LATERAL (SELECT ` + tenant + ` AS tenant_id, ` + member + `::text AS member_id, lc.msg_id) le
		WHERE true` + flowDoorSQL("le", "lc", pub) + ` AND NOT ` + flowCoveredSQL("le", "lc", now, lobby)
}

// flowEventCountsSQL is flowCountsSQL over the member's flow events only:
// the counts, and the keys of those events.
//
// It reads only the tail past each place's read mark (api perf ap-01b):
// fp walks the member's distinct place_key values on flow_events_place (one
// probe each, rdb 0137), fb takes each place's newest place mark (a DM place
// dm:<from>@<box> also takes dm:<from>), and ft seeks past it on cov_at.
// Every event before that mark is covered by it, so it can be skipped; the
// cut is inclusive (a tie on cov_at is decided by msg_id below). An event
// whose keys are not stored yet is always in the tail. The per-message rules
// (the door, the archive, f: and t: marks and both DM marks) then run as
// before, on that tail only.
//
// The shape is what makes those seeks happen (ap-01b follow-up, measured on
// prd: 42 -> 4 ms p50). The tail is a LATERAL per place with OFFSET 0, so
// the planner cannot flatten it into one hash join over all the member's
// events; fb is never NULL (coalesce inside the mark), so cov_at >= fb.at is
// an index condition on flow_events_place; and each tail event takes its
// message by one primary-key probe (LATERAL ... LIMIT 1) instead of a hash of
// every message in the tenant. Same rows, same counts.
func flowEventCountsSQL(tenant, member, now, pub, lobby string) string {
	return `WITH RECURSIVE fp(k) AS (SELECT min(x.place_key) FROM flow_events x WHERE x.tenant_id = ` + tenant + ` AND x.member_id = ` + member + `
			UNION ALL SELECT (SELECT min(x.place_key) FROM flow_events x WHERE x.tenant_id = ` + tenant + ` AND x.member_id = ` + member + ` AND x.place_key > fp.k)
			FROM fp WHERE fp.k IS NOT NULL),
		ft AS (SELECT fe.* FROM fp
			CROSS JOIN LATERAL (SELECT coalesce(max(r.at), '-infinity'::timestamptz) AS at FROM read_marks r WHERE r.tenant_id = ` + tenant + ` AND r.member_id = ` + member + `
				AND r.mark_key IN (fp.k, CASE WHEN fp.k LIKE 'dm:%@%' THEN regexp_replace(fp.k, '@[^@]*$', '') END)) fb
			CROSS JOIN LATERAL (SELECT fe.tenant_id, fe.member_id, fe.msg_id, fe.kind, fe.at, fe.expires_at FROM flow_events fe
				WHERE fe.tenant_id = ` + tenant + ` AND fe.member_id = ` + member + ` AND fe.place_key = fp.k
				AND fe.cov_at >= fb.at OFFSET 0) fe
			WHERE fp.k IS NOT NULL
			UNION ALL SELECT fe.tenant_id, fe.member_id, fe.msg_id, fe.kind, fe.at, fe.expires_at FROM flow_events fe
			WHERE fe.tenant_id = ` + tenant + ` AND fe.member_id = ` + member + ` AND (fe.place_key IS NULL OR fe.cov_at IS NULL)
			UNION ALL ` + flowThreadTailSQL(tenant, member, lobby) + `),
		fc AS (SELECT fe.kind, fm.channel IS NOT NULL AS in_ch,
				CASE WHEN fm.channel IS NOT NULL THEN 'ch:' || fm.channel
					WHEN coalesce(fm.from_box, '') <> '' THEN 'dm:' || fm.from_id || '@' || fm.from_box
					ELSE 'dm:' || fm.from_id END AS place_key,
				't:' || fm.task_id::text AS topic_key,
				fe.at > coalesce((SELECT s.at FROM read_marks s
				WHERE s.tenant_id = ` + tenant + ` AND s.member_id = ` + member + ` AND s.mark_key = 'f:seen'), '-infinity'::timestamptz) AS unseen
			FROM ft fe CROSS JOIN LATERAL (SELECT fm.channel, fm.from_box, fm.from_id, fm.to_box, fm.to_id, fm.task_id, fm.parent_task_id, fm.msg_id, fm.received_at, fm.expires_at FROM messages fm WHERE fm.tenant_id = fe.tenant_id AND fm.msg_id = fe.msg_id LIMIT 1) fm
			WHERE fe.expires_at > ` + now + ` AND fm.expires_at > ` + now +
		flowDoorSQL("fe", "fm", pub) + ` AND NOT ` + flowCoveredSQL("fe", "fm", now, lobby) + `)
		SELECT count(*) FILTER (WHERE fc.unseen AND fc.kind IN ('mention', 'poke', 'blocked', 'ready')),
			count(*) FILTER (WHERE fc.unseen AND fc.kind = 'reply'),
			count(*) FILTER (WHERE fc.unseen AND fc.kind = 'dm'),
			count(*) FILTER (WHERE fc.unseen AND fc.in_ch),
			count(*) FILTER (WHERE fc.unseen AND NOT fc.in_ch),
			count(*) FILTER (WHERE fc.kind IN ('mention', 'poke', 'blocked', 'ready')),
			count(*) FILTER (WHERE fc.kind = 'reply'),
			count(*) FILTER (WHERE fc.kind = 'dm'),
			count(*) FILTER (WHERE fc.in_ch),
			count(*) FILTER (WHERE NOT fc.in_ch),
			(SELECT count(DISTINCT (r.released_at AT TIME ZONE 'UTC')::date) FROM release_notes r
				WHERE r.released_at IS NOT NULL AND r.version IS NOT NULL AND r.released_at <= ` + now + `
				  AND r.released_at > (SELECT s.at FROM read_marks s WHERE s.tenant_id = ` + tenant + ` AND s.member_id = ` + member + ` AND s.mark_key = 'f:seen')),
			(SELECT coalesce(jsonb_object_agg(k.key, k.n), '{}'::jsonb) FROM (SELECT x.key, count(*) AS n
				FROM fc f2 CROSS JOIN LATERAL (VALUES (f2.place_key), (f2.topic_key)) x(key) GROUP BY x.key) k)
		FROM fc`
}

// flowThreadTailSQL is the rest of the tail (SPL-2124): the channel events
// the ch: cut above skipped (cov_at before the place's mark) that a t: mark
// of the member may still leave unread, since the thread mark, not ch:,
// decides a topic's lines (flowCoveredSQL). Driven by the member's live t:
// marks (threadMarksSQL): one range on messages_task_received per mark, past
// the mark, then one flow_events probe per line found. The cut's complement
// keeps every event in one branch only.
func flowThreadTailSQL(tenant, member, lobby string) string {
	return `SELECT fe.tenant_id, fe.member_id, fe.msg_id, fe.kind, fe.at, fe.expires_at FROM ` + threadMarksSQL(tenant, member, lobby) + `
			CROSS JOIN LATERAL (SELECT x.msg_id FROM messages x WHERE x.tenant_id = ` + tenant + `
				AND x.task_id = k.task AND x.received_at >= tm.at AND x.channel IS NOT NULL OFFSET 0) x
			JOIN flow_events fe ON fe.tenant_id = ` + tenant + ` AND fe.member_id = ` + member + ` AND fe.msg_id = x.msg_id
			WHERE fe.place_key LIKE 'ch:%' AND fe.cov_at < (SELECT max(r.at) FROM read_marks r
				WHERE r.tenant_id = ` + tenant + ` AND r.member_id = ` + member + ` AND r.mark_key = fe.place_key)`
}

// threadMarksSQL is "read_marks tm, k(task)": the member's t: marks with the
// topic id as a uuid that have a line at or past the mark (one index-only
// probe of messages_task_received), less the topics whose lines are all
// hidden as archived (archivedHideSQL's task arm, one messages_archived probe
// per mark left; on prd t1 most of a heavy reader's marks are archived
// topics). It drops only lines the outer read or the archive rule drops
// anyway.
func threadMarksSQL(tenant, member, lobby string) string {
	return `read_marks tm
			CROSS JOIN LATERAL (SELECT CASE WHEN substr(tm.mark_key, 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN substr(tm.mark_key, 3)::uuid END AS task OFFSET 0) k
			JOIN LATERAL (SELECT 1 WHERE tm.tenant_id = ` + tenant + ` AND tm.member_id = ` + member + ` AND tm.mark_key LIKE 't:%' AND k.task IS NOT NULL
				AND EXISTS (SELECT 1 FROM messages y WHERE y.tenant_id = ` + tenant + ` AND y.task_id = k.task AND y.received_at >= tm.at)
				AND NOT EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = ` + tenant + ` AND z.task_id = k.task AND z.archived_at IS NOT NULL AND k.task::text <> ` + lobby + `)) live ON true`
}

// flowEventCols are the FlowEvent columns of event e / message m, scanned
// by scanFlowEvent.
func flowEventCols(e, m, now, lobby string) string {
	return e + `.msg_id::text, ` + m + `.task_id::text, coalesce(` + m + `.parent_task_id::text, ''), coalesce(` + m + `.channel, ''),
		` + m + `.from_id, ` + m + `.from_box, coalesce(` + m + `.to_id, ''), coalesce(` + m + `.to_box, ''), coalesce(` + m + `.typed_by, ''),
		` + e + `.kind, left(` + m + `.body, 400), CASE WHEN jsonb_typeof(` + m + `.files) = 'array' THEN jsonb_array_length(` + m + `.files) ELSE 0 END,
		` + m + `.received_at, NOT ` + flowCoveredSQL(e, m, now, lobby)
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
	return []any{&c.Mention, &c.Reply, &c.DM, &c.Channels, &c.DMs, &u.Mention, &u.Reply, &u.DM, &u.Channels, &u.DMs, &c.Release, keys}
}

// flowKindsFilter is the kind= filter as kind values (nil = all).
func flowKindsFilter(kind string) []string {
	switch kind {
	case "":
		return nil
	case FlowMention:
		return []string{FlowMention, FlowPoke, FlowBlocked, FlowReady}
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
			sql: `SELECT ` + flowEventCols("e", "m", "$3", "$9::text") + `
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
	err := s.queryTenant(ctx, tenant, `SELECT `+flowEventCols("e", "m", "$4", "$6::text")+`, e.member_id, c.*
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
// and is deleted as before; a release mark f:rel:<version> (spec 130) has no
// message and is kept. gone is materialized once, so the DELETE does not
// re-run the anti-join per read_marks row.
const flowMarkSweepSQL = `WITH r AS MATERIALIZED (
		SELECT tenant_id, member_id, mark_key,
			CASE WHEN substr(mark_key, 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
				THEN substr(mark_key, 3)::uuid END AS msg_id
		FROM read_marks WHERE mark_key LIKE 'f:%' AND mark_key <> 'f:seen' AND mark_key NOT LIKE 'f:rel:%' AND updated_at <= $1),
	gone AS MATERIALIZED (SELECT r.tenant_id, r.member_id, r.mark_key FROM r
		WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = r.tenant_id AND m.msg_id = r.msg_id)
		LIMIT $2)
	DELETE FROM read_marks d USING gone g
	WHERE d.tenant_id = g.tenant_id AND d.member_id = g.member_id AND d.mark_key = g.mark_key`
