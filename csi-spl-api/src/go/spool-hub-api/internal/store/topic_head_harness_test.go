package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 099 T001: the topic-head case table (spec 4.3, E01..E28 plus the
// writers the panel found since) as data, run against TODAY's code. Each case
// seeds a small tenant, applies its writes through the store's own methods
// (never raw SQL, so a later trigger sees what prd sees), and then, for every
// list shape (topicHeadShapes) and every page, compares the live walk
// (ViewTopics) with refTopicsSQL: a whole-tenant aggregate that states every
// rule of spec section 2 - the read door, the archived hide, roots / parent /
// NoIssues - in the plainest SQL. The pre-027 oracleTopicsSQL has no door
// and no archived hide, so it cannot be the oracle for a reader shape.
//
// Today this proves the case table and the reference are right before any
// head exists. T005 sets topicHeadRead and the same run compares the head
// read too; once rdb has topic_head_diff, every case also asserts it is empty.
// Postgres only (SPOOL_TEST_PG_DSN).

// topicHeadRead is the head read under test; nil until T005 lands it.
var topicHeadRead func(ctx context.Context, s *Postgres, tenant string, q TopicQuery) ([]TopicRow, error)

// refTopicsSQL: the list contract of spec section 2 as one aggregate.
// $1 tenant $2 now $3 channel $4 dm $5 agent $6 agent box $7 viewer $8 roots
// $9 parent $10 no-issues $11 lobby $12 reader $13 public channels
// $14 reader's channels $15 before at $16 before task $17 limit $18 task ids.
const refTopicsSQL = `WITH d AS (
			SELECT m.*, ($12::text = '' OR m.channel = ANY($13::text[]) OR m.channel = ANY($14::text[])
				OR (m.channel IS NULL AND (m.from_id = $12::text OR m.to_id = $12::text))) AS door
			FROM messages m
			WHERE m.tenant_id = $1 AND m.expires_at > $2 AND ($3::text = '' OR m.channel = $3::text)
				AND (NOT $4::bool OR m.channel IS NULL)
		), t AS (
			SELECT task_id, max(received_at) AS last_at,
				(array_agg(parent_task_id::text ORDER BY received_at, msg_id::text))[1] AS first_parent
			FROM d GROUP BY task_id
			HAVING bool_or(door)
				AND ($5::text = '' OR bool_or((from_id = $5::text AND ($6::text = '' OR from_box = $6::text))
					OR (to_id = $5::text AND ($6::text = '' OR to_box = $6::text))))
				AND ($7::text = '' OR bool_or(from_id = $7::text OR to_id = $7::text))
		), s AS (
			SELECT t.task_id, t.last_at FROM t
			WHERE (NOT $8::bool OR t.first_parent IS NULL)
				AND ($9::text = '' OR (t.first_parent = $9::text AND t.task_id IN (
					SELECT p.task_id FROM messages p WHERE p.tenant_id = $1 AND p.parent_task_id::text = $9::text)))
				AND (NOT $10::bool OR NOT EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = $1 AND i.task_id = t.task_id))
				AND NOT EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = $1 AND z.archived_at IS NOT NULL
					AND (z.msg_id = t.task_id OR (z.task_id = t.task_id AND t.task_id::text <> $11::text)))
				AND ($15::timestamptz IS NULL OR (t.last_at, t.task_id::text) < ($15::timestamptz, $16::text))
				AND ($18::text[] IS NULL OR t.task_id::text = ANY($18::text[]))
			ORDER BY t.last_at DESC, t.task_id::text DESC LIMIT $17
		)
		SELECT s.task_id::text,
			(array_agg(COALESCE(d.channel, '') ORDER BY d.received_at, d.msg_id::text))[1],
			(array_agg(COALESCE(d.parent_task_id::text, '') ORDER BY d.received_at, d.msg_id::text))[1],
			min(d.received_at), s.last_at, count(*)::int,
			array_agg(d.kind ORDER BY d.received_at, d.msg_id::text),
			array_agg(d.from_id || '@' || d.from_box) || array_agg(d.to_id || '@' || d.to_box),
			(array_agg(d.msg ORDER BY d.received_at, d.msg_id::text))[1]
		FROM s JOIN d ON d.task_id = s.task_id AND d.door
		GROUP BY s.task_id, s.last_at
		ORDER BY s.last_at DESC, s.task_id::text DESC`

func refTopics(ctx context.Context, s *Postgres, tenant string, q TopicQuery) ([]TopicRow, error) {
	return refTopicsWith(ctx, s, refTopicsSQL, tenant, q)
}

func refTopicsWith(ctx context.Context, s *Postgres, sql, tenant string, q TopicQuery) ([]TopicRow, error) {
	var ids []string
	if len(q.TaskIDs) > 0 {
		ids = q.TaskIDs
	}
	var out []TopicRow
	err := s.queryTenant(ctx, tenant, sql, []any{tenant, q.Now, q.Channel, q.DM, q.Agent, q.AgentBox, q.Viewer,
		q.Roots, q.Parent, q.NoIssues, q.Lobby, q.Reader, PublicChannels, q.ReaderChannels,
		optTime(q.BeforeAt), q.BeforeTask, pgLimit(q.Limit), ids}, scanTopicRows(&out))
	return out, err
}

// headFix is one case's tenant: named tasks and lines, the base clock t0 and
// the list clock now (a case moves now past an expiry without a sweep).
type headFix struct {
	t      *testing.T
	pg     *Postgres
	tn     string
	t0     time.Time
	now    time.Time
	task   map[string]string // name -> task id
	msg    map[string]string // name -> msg id
	parent string            // a parent with a child topic, for the parent= shape
}

// lineOpt shapes one line; the zero value is a #lobby line AGT-1@box-a ->
// HUM-1@box-wui, kind task, 30 days to live. ch "-" is a DM. mirror names
// the DM line this one is the channel copy of (spec 067, messages.mirror_of).
type lineOpt struct {
	ch, from, fromBox, to, toBox, kind, body, parent, mirror string
	card                                                     bool // msg_id = task_id (the topic's card)
	ttl                                                      time.Duration
}

// line inserts one line named name into the task named task, ago before t0.
func (f *headFix) line(name, task string, ago time.Duration, o lineOpt) string {
	f.t.Helper()
	m := f.lineMsg(name, task, ago, o)
	if _, err := f.pg.InsertMessage(context.Background(), m); err != nil {
		f.t.Fatalf("insert %s: %v", name, err)
	}
	return m.MsgID
}

// lineMsg is the row line inserts, named but not stored yet.
func (f *headFix) lineMsg(name, task string, ago time.Duration, o lineOpt) Message {
	f.t.Helper()
	if f.task[task] == "" {
		f.task[task] = uuid4()
	}
	at := f.t0.Add(-ago)
	m := msgFor(f.tn, f.task[task], "box-wui", at, at, "env-"+uuid4())
	m.Channel, m.FromID, m.FromBox, m.ToID, m.ToBox, m.Kind = ChannelLobby, "AGT-1", "box-a", "HUM-1", "box-wui", "task"
	switch o.ch {
	case "":
	case "-":
		m.Channel = ""
	default:
		m.Channel = o.ch
	}
	for _, kv := range [][2]*string{{&m.FromID, &o.from}, {&m.FromBox, &o.fromBox}, {&m.ToID, &o.to}, {&m.ToBox, &o.toBox}, {&m.Kind, &o.kind}} {
		if *kv[1] != "" {
			*kv[0] = *kv[1]
		}
	}
	if o.card { // the opener, as the hub stores one (ArchiveChannel stamps only is_parent rows)
		m.MsgID, m.IsParent = m.TaskID, 1
	}
	if o.parent != "" {
		m.ParentTaskID = f.task[o.parent]
	}
	if o.ttl != 0 {
		m.ExpiresAt = at.Add(o.ttl)
	}
	m.Body = o.body
	if m.Body == "" {
		m.Body = name + " line"
	}
	m.Msg, _ = json.Marshal(map[string]any{"v": 1, "body": m.Body})
	if o.mirror != "" { // the copy's own envelope, as editMirrorsTx re-encodes it
		m.MirrorOf = f.msg[o.mirror]
		m.Env, _ = json.Marshal(map[string]any{"from_box": m.FromBox, "to_box": m.ToBox, "msg": json.RawMessage(m.Msg), "sig": ""})
	}
	f.msg[name] = m.MsgID
	return m
}

// edit is an Edit to body.
func (f *headFix) edit(body string) Edit {
	msg, _ := json.Marshal(map[string]any{"v": 1, "body": body})
	return Edit{Body: body, Msg: msg, Env: []byte(`{"e":"` + uuid4() + `"}`), EditedBy: "HUM-1", EditedAt: f.t0}
}

func (f *headFix) must(what string, err error) {
	f.t.Helper()
	if err != nil {
		f.t.Fatalf("%s: %v", what, err)
	}
}

// seedHeadFix is the base every case starts from: a lobby task with replies,
// a #lobby topic A (card + 2 replies), a topic B in the created channel #crew,
// a DM topic D (HUM-1 <-> AGT-1), a child topic K of A, and an issue
// discussion I in #issues with its issues row.
func seedHeadFix(t *testing.T, pg *Postgres, t0 time.Time) *headFix {
	f := &headFix{t: t, pg: pg, tn: newTenant(t, pg), t0: t0, now: t0, task: map[string]string{}, msg: map[string]string{}}
	ctx := context.Background()
	f.must("crew", pg.CreateChannel(ctx, Channel{TenantID: f.tn, ChannelID: "crew", Name: "crew", CreatedBy: "HUM-1"}))
	f.line("lobby0", "lobby", 90*time.Minute, lineOpt{card: true, from: "HUM-2", fromBox: "box-wui", to: "ALL-0"})
	f.line("lobby1", "lobby", 80*time.Minute, lineOpt{from: "AGT-2", fromBox: "box-b", to: "ALL-0", kind: "note"})
	f.line("a0", "A", 60*time.Minute, lineOpt{card: true, body: "   alpha subject\nsecond line"})
	f.line("a1", "A", 50*time.Minute, lineOpt{from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a", kind: "result"})
	f.line("a2", "A", 40*time.Minute, lineOpt{from: "AGT-2", fromBox: "box-b", to: "AGT-1", toBox: "box-a", kind: "note"})
	f.line("b0", "B", 55*time.Minute, lineOpt{card: true, ch: "crew", from: "HUM-1", fromBox: "box-wui", to: "ALL-0"})
	f.line("b1", "B", 35*time.Minute, lineOpt{ch: "crew", from: "AGT-3", fromBox: "box-b", to: "HUM-1"})
	f.line("d0", "D", 45*time.Minute, lineOpt{card: true, ch: "-", from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a"})
	f.line("d1", "D", 30*time.Minute, lineOpt{ch: "-", from: "AGT-1", fromBox: "box-a", to: "HUM-1", toBox: "box-wui", kind: "result"})
	f.line("k0", "K", 25*time.Minute, lineOpt{card: true, parent: "A", body: "child of alpha"})
	f.line("i0", "I", 20*time.Minute, lineOpt{card: true, ch: ChannelIssues, from: "HUM-2", fromBox: "box-wui", to: "ALL-0"})
	_, err := pg.CreateIssue(ctx, Issue{TenantID: f.tn, Title: "an issue", TaskID: f.task["I"], CreatedBy: "HUM-2"}, t0)
	f.must("issue", err)
	f.parent = f.task["A"]
	return f
}

// headCase is one row of the case table: its writes, and what the plain
// list (no filter, no reader) must show afterwards - the check that the case
// did what its name says, so a case can never pass vacuously.
type headCase struct {
	id, what string
	apply    func(f *headFix)
	expect   func(f *headFix, rows map[string]TopicRow) string
	serial   bool // runs alone: Sweep is global
}

func countIs(f *headFix, rows map[string]TopicRow, task string, n int) string {
	r, ok := rows[f.task[task]]
	if !ok {
		return task + " not listed"
	}
	if r.Count != n {
		return fmt.Sprintf("%s count %d, want %d", task, r.Count, n)
	}
	return ""
}

func absent(f *headFix, rows map[string]TopicRow, task string) string {
	if _, ok := rows[f.task[task]]; ok {
		return task + " still listed"
	}
	return ""
}

func subjectIs(f *headFix, rows map[string]TopicRow, task, want string) string {
	if s := topicSubject(rows[f.task[task]].FirstMsg); s != want {
		return fmt.Sprintf("%s subject %q, want %q", task, s, want)
	}
	return ""
}

func firstOf(errs ...string) string {
	for _, e := range errs {
		if e != "" {
			return e
		}
	}
	return ""
}

const headTTL = time.Minute // an expiring line lives 1 min from its received_at

// expireOne: a line received 30 s before t0 that expires 30 s after it; the
// list clock moves to t0 + 1 min, past it, and nothing is swept.
func expireOne(f *headFix, name, task string, o lineOpt) {
	o.ttl = headTTL
	f.line(name, task, 30*time.Second, o)
	f.now = f.t0.Add(time.Minute)
}

func archive(f *headFix, msg string, on bool) {
	_, err := f.pg.SetArchived(context.Background(), f.tn, f.msg[msg], "HUM-1", f.t0, on)
	f.must("archive "+msg, err)
}

var dmHumAgt = lineOpt{ch: "-", from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a"}

// headCases is spec 4.3's table. Ids follow the spec; a "b" id is the undo of
// the case before it, and E29+ are writers the spec v0.1 does not list.
// E25 (tenant delete) has nothing to compare before heads exist: T003.
func headCases() []headCase {
	ctx := context.Background()
	return append([]headCase{
		{id: "E01", what: "insert a channel line", apply: func(f *headFix) { f.line("a3", "A", time.Minute, lineOpt{}) },
			expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 4) }},
		{id: "E02", what: "insert a DM line", apply: func(f *headFix) { f.line("d2", "D", time.Minute, dmHumAgt) },
			expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "D", 3) }},
		{id: "E03", what: "insert into a topic whose card is archived", apply: func(f *headFix) {
			f.line("x0", "X", 10*time.Minute, lineOpt{card: true})
			archive(f, "x0", true)
			f.line("x1", "X", time.Minute, lineOpt{})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "X") }},
		{id: "E04", what: "edit the first line (the subject)", apply: func(f *headFix) {
			_, err := f.pg.ApplyEdit(ctx, f.tn, f.msg["a0"], f.edit("renamed alpha"))
			f.must("edit", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string { return subjectIs(f, r, "A", "renamed alpha") }},
		{id: "E05", what: "edit another line", apply: func(f *headFix) {
			_, err := f.pg.ApplyEdit(ctx, f.tn, f.msg["a1"], f.edit("edited reply"))
			f.must("edit", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string { return subjectIs(f, r, "A", "alpha subject") }},
		{id: "E06", what: "kind change", apply: func(f *headFix) {
			_, err := f.pg.SetKind(ctx, f.tn, f.msg["a2"], "reject", "HUM-1", f.t0)
			f.must("kind", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			if k := fmt.Sprint(r[f.task["A"]].Kinds); k != "[task result reject]" {
				return "A kinds " + k
			}
			return ""
		}},
		{id: "E07", what: "move a line to another topic and channel", apply: func(f *headFix) {
			_, err := f.pg.MoveMessage(ctx, f.tn, f.msg["a2"], f.task["B"], "crew", "HUM-1", f.t0, time.Time{})
			f.must("move", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 2), countIs(f, r, "B", 3))
		}},
		{id: "E08", what: "move a #crew line into a #lobby topic", apply: func(f *headFix) {
			_, err := f.pg.MoveMessage(ctx, f.tn, f.msg["b1"], f.task["A"], ChannelLobby, "HUM-1", f.t0, time.Time{})
			f.must("move", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 4), countIs(f, r, "B", 1))
		}},
		{id: "E09", what: "move a whole topic to another channel", apply: func(f *headFix) {
			_, err := f.pg.MoveTopic(ctx, f.tn, f.msg["a0"], f.task["A"], "crew", "HUM-1", f.t0)
			f.must("move topic", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			if c := r[f.task["A"]].Channel; c != "crew" {
				return "A channel " + c
			}
			return ""
		}},
		{id: "E10", what: "merge topic B into A", apply: func(f *headFix) {
			_, err := f.pg.MergeTopic(ctx, f.tn, f.msg["b0"], f.task["B"], f.task["A"], ChannelLobby, "HUM-1", f.t0)
			f.must("merge", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 5), absent(f, r, "B"))
		}},
		{id: "E11", what: "merge then unmerge", apply: func(f *headFix) {
			res, err := f.pg.MergeTopic(ctx, f.tn, f.msg["b0"], f.task["B"], f.task["A"], ChannelLobby, "HUM-1", f.t0)
			f.must("merge", err)
			f.must("unmerge", f.pg.UnmergeTopic(ctx, f.tn, f.msg["b0"], res.MsgIDs))
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 3), countIs(f, r, "B", 2))
		}},
		{id: "E12", what: "promote a line to a topic", apply: func(f *headFix) {
			f.task["P"] = uuid4()
			_, err := f.pg.PromoteMessage(ctx, f.tn, f.msg["a2"], f.task["A"], f.task["P"], "HUM-1", f.t0)
			f.must("promote", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 2), countIs(f, r, "P", 1))
		}},
		{id: "E12b", what: "promote then demote", apply: func(f *headFix) {
			f.task["P"] = uuid4()
			res, err := f.pg.PromoteMessage(ctx, f.tn, f.msg["a2"], f.task["A"], f.task["P"], "HUM-1", f.t0)
			f.must("promote", err)
			f.must("demote", f.pg.DemoteTopic(ctx, f.tn, f.msg["a2"], res.MsgIDs))
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 3), absent(f, r, "P"))
		}},
		{id: "E13", what: "archive the card", apply: func(f *headFix) { archive(f, "a0", true) },
			expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "A") }},
		{id: "E13b", what: "archive then unarchive the card", apply: func(f *headFix) { archive(f, "a0", true); archive(f, "a0", false) },
			expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 3) }},
		{id: "E14", what: "archive a reply in a topic", apply: func(f *headFix) { archive(f, "a1", true) },
			expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "A") }},
		{id: "E15", what: "archive a reply in the lobby", apply: func(f *headFix) { archive(f, "lobby1", true) },
			expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "lobby", 2) }},
		{id: "E16", what: "delete a line", apply: func(f *headFix) { f.must("delete", f.pg.DeleteMessage(ctx, f.tn, f.msg["a2"])) },
			expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 2) }},
		{id: "E17", what: "merge two lines", apply: func(f *headFix) {
			_, err := f.pg.MergeMessages(ctx, f.tn, f.msg["a1"], f.msg["a2"], f.edit("merged reply"))
			f.must("merge lines", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 2) }},
		{id: "E18", what: "delete a topic (and its child)", apply: func(f *headFix) {
			_, err := f.pg.DeleteTopic(ctx, f.tn, f.msg["a0"], f.task["A"])
			f.must("delete topic", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string { return firstOf(absent(f, r, "A"), absent(f, r, "K")) }},
		{id: "E19", what: "delete a channel", apply: func(f *headFix) {
			f.line("a3", "A", time.Minute, lineOpt{ch: "crew"})
			f.must("delete channel", f.pg.DeleteChannel(ctx, f.tn, "crew", "HUM-1", f.t0))
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(absent(f, r, "B"), countIs(f, r, "A", 3))
		}},
		{id: "E20", what: "the latest line expires, unswept", apply: func(f *headFix) { expireOne(f, "a3", "A", lineOpt{}) },
			expect: func(f *headFix, r map[string]TopicRow) string {
				if !r[f.task["A"]].LastAt.Equal(f.t0.Add(-40 * time.Minute)) {
					return "A last_at " + r[f.task["A"]].LastAt.String()
				}
				return countIs(f, r, "A", 3)
			}},
		{id: "E21", what: "the first line expires (the subject moves)", apply: func(f *headFix) {
			f.line("y0", "Y", 30*time.Second, lineOpt{card: true, ttl: headTTL, body: "old subject"})
			f.line("y1", "Y", 10*time.Second, lineOpt{body: "new subject"})
			f.now = f.t0.Add(time.Minute)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(subjectIs(f, r, "Y", "new subject"), countIs(f, r, "Y", 1))
		}},
		{id: "E22", what: "the only line expires", apply: func(f *headFix) { expireOne(f, "z0", "Z", lineOpt{card: true}) },
			expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "Z") }},
		{id: "E23", what: "an archived row expires (it still hides its topic)", apply: func(f *headFix) {
			f.line("w0", "W", 20*time.Minute, lineOpt{card: true})
			f.line("w1", "W", 30*time.Second, lineOpt{ttl: headTTL})
			archive(f, "w1", true)
			f.now = f.t0.Add(time.Minute)
		}, expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "W") }},
		{id: "E24", what: "the sweep purges expired lines", serial: true, apply: func(f *headFix) {
			expireOne(f, "a3", "A", lineOpt{})
			f.line("z0", "Z", 30*time.Second, lineOpt{card: true, ttl: headTTL})
			_, err := f.pg.Sweep(ctx, f.now)
			f.must("sweep", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			var n int
			f.must("count", f.pg.queryRowTenant(ctx, f.tn, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`,
				[]any{f.tn, []string{f.msg["a3"], f.msg["z0"]}}, &n))
			if n != 0 {
				return fmt.Sprintf("%d expired lines left after the sweep", n)
			}
			return firstOf(countIs(f, r, "A", 3), absent(f, r, "Z"))
		}},
		{id: "E26", what: "one topic with a channel part and a DM part", apply: func(f *headFix) {
			f.line("m0", "M", 15*time.Minute, lineOpt{card: true, from: "AGT-2", fromBox: "box-b", to: "ALL-0", body: "mixed lobby"})
			f.line("m1", "M", 14*time.Minute, lineOpt{ch: "-", from: "HUM-2", fromBox: "box-wui", to: "AGT-2", toBox: "box-b", kind: "note"})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "M", 2) }},
		{id: "E27", what: "one topic, two DM pairs", apply: func(f *headFix) {
			f.line("n0", "N", 15*time.Minute, lineOpt{card: true, ch: "-", from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a"})
			f.line("n1", "N", 14*time.Minute, lineOpt{ch: "-", from: "HUM-2", fromBox: "box-wui", to: "AGT-1", toBox: "box-a"})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "N", 2) }},
		{id: "E28", what: "5 topics at one received_at, a page boundary inside the tie", apply: func(f *headFix) {
			f.line("t1", "T1", 2*time.Minute, lineOpt{card: true})
			o := dmHumAgt
			o.card = true
			f.line("t2", "T2", 2*time.Minute, o)
			f.line("t3", "T3", 2*time.Minute, lineOpt{card: true, ch: "crew"})
			f.line("t4", "T4", 2*time.Minute, lineOpt{card: true, from: "AGT-2", fromBox: "box-b"})
			f.line("t5", "T5", 2*time.Minute, lineOpt{card: true, to: "AGT-1", toBox: "box-a"})
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "T1", 1), countIs(f, r, "T5", 1), boundaryAt(f, f.t0.Add(-2*time.Minute), 2))
		}},
		{id: "E29", what: "archive a channel (stamps its topic cards)", apply: func(f *headFix) {
			f.must("archive channel", f.pg.ArchiveChannel(ctx, f.tn, "crew", "HUM-1", f.t0))
		}, expect: func(f *headFix, r map[string]TopicRow) string { return absent(f, r, "B") }},
		{id: "E30", what: "a child topic gains a line in another channel", apply: func(f *headFix) {
			f.line("k1", "K", time.Minute, lineOpt{parent: "A", ch: "crew"})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "K", 2) }},
	}, headCasesT001b()...)
}

// boundaryAt pages the plain list at limit 3 and asserts the page that ends
// after `pages` pages is cut between two topics both last at `at`: the cursor
// lands inside a tie (E28), or on a due topic (E20p, pages 1 and at = its
// key once its newest line expired).
func boundaryAt(f *headFix, at time.Time, pages int) string {
	q := TopicQuery{Now: f.now, Lobby: f.task["lobby"], Limit: 3}
	var all []TopicRow
	for p := 0; p < pages; p++ {
		rows, err := f.pg.ViewTopics(context.Background(), f.tn, q)
		f.must("page", err)
		all = append(all, rows...)
		if len(rows) < q.Limit {
			break
		}
		q.BeforeAt, q.BeforeTask = rows[len(rows)-1].LastAt, rows[len(rows)-1].TaskID
	}
	if len(all) < 3 || (pages > 1 && len(all) < 4) {
		return fmt.Sprintf("only %d rows on the first %d pages", len(all), pages)
	}
	if !all[2].LastAt.Equal(at) {
		return "page 1 ends at " + all[2].LastAt.String() + ", want " + at.String()
	}
	if pages > 1 && !all[3].LastAt.Equal(at) {
		return "page 2 starts at " + all[3].LastAt.String() + ": the boundary is not inside the tie"
	}
	return ""
}

// parentIs asserts task's listed parent.
func parentIs(f *headFix, rows map[string]TopicRow, task, parent string) string {
	if p := rows[f.task[task]].Parent; p != f.task[parent] {
		return fmt.Sprintf("%s parent %q, want %s %q", task, p, parent, f.task[parent])
	}
	return ""
}

// bodyOf is the stored body of the line named name.
func bodyOf(f *headFix, name string) string {
	var b string
	f.must("body "+name, f.pg.queryRowTenant(context.Background(), f.tn,
		`SELECT body FROM messages WHERE tenant_id = $1 AND msg_id = $2`, []any{f.tn, f.msg[name]}, &b))
	return b
}

// dropHeads deletes task's head rows as operator, standing for a topic
// written before the DDL (E41); before T002 there are no head tables and it
// does nothing, so E41 is E01 today.
func dropHeads(f *headFix, task string) {
	ctx := context.Background()
	var reg *string
	f.must("probe", f.pg.pool.QueryRow(ctx, `SELECT to_regclass('topic_heads')::text`).Scan(&reg))
	if reg == nil {
		return
	}
	f.must("drop heads", f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		for _, tbl := range []string{"topic_head_parts", "topic_heads"} {
			if _, err := tx.Exec(ctx, `DELETE FROM `+tbl+` WHERE tenant_id = $1 AND task_id = $2`, f.tn, f.task[task]); err != nil {
				return err
			}
		}
		return nil
	}))
}

// headCasesT001b are spec 099 T001b's cases: E20p and E31..E41 (claude-3
// F3, F4), each the fixture one reference control or one writer needs.
func headCasesT001b() []headCase {
	ctx := context.Background()
	return []headCase{
		{id: "E20p", what: "a due topic exactly at a page boundary", apply: func(f *headFix) {
			f.line("q0", "Q", 27*time.Minute, lineOpt{card: true})
			expireOne(f, "q1", "Q", lineOpt{})
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "Q", 1), boundaryAt(f, f.t0.Add(-27*time.Minute), 1))
		}},
		{id: "E31", what: "a card that has left its topic is archived", apply: func(f *headFix) {
			_, err := f.pg.MoveMessage(ctx, f.tn, f.msg["b0"], f.task["lobby"], ChannelLobby, "HUM-1", f.t0, time.Time{})
			f.must("move card", err)
			archive(f, "b0", true)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(absent(f, r, "B"), countIs(f, r, "lobby", 3))
		}},
		{id: "E32", what: "one agent on two boxes", apply: func(f *headFix) {
			f.line("b2", "B", 33*time.Minute, lineOpt{ch: "crew", from: "AGT-1", fromBox: "box-b", to: "HUM-1"})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "B", 3) }},
		{id: "E33", what: "a child topic whose first line is in a created channel", apply: func(f *headFix) {
			f.line("c0", "C", 24*time.Minute, lineOpt{card: true, ch: "crew", parent: "A", body: "crew child"})
			f.line("c1", "C", 23*time.Minute, lineOpt{from: "AGT-2", fromBox: "box-b", to: "ALL-0"})
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "C", 2), parentIs(f, r, "C", "A"))
		}},
		{id: "E34", what: "a duplicate resend", apply: func(f *headFix) {
			m := f.lineMsg("a3", "A", time.Minute, lineOpt{})
			for i, want := range []bool{true, false} {
				ok, err := f.pg.InsertMessage(ctx, m)
				f.must("resend", err)
				if ok != want {
					f.t.Fatalf("insert %d of one line: inserted=%v", i+1, ok)
				}
			}
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 4) }},
		{id: "E35", what: "a DM card with a mirror is archived", apply: func(f *headFix) {
			f.line("cp", "A", 44*time.Minute, lineOpt{from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a", mirror: "d0"})
			archive(f, "d0", true)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(absent(f, r, "D"), absent(f, r, "A"))
		}},
		{id: "E35b", what: "a DM card with a mirror is archived, then unarchived", apply: func(f *headFix) {
			f.line("cp", "A", 44*time.Minute, lineOpt{from: "HUM-1", fromBox: "box-wui", to: "AGT-1", toBox: "box-a", mirror: "d0"})
			archive(f, "d0", true)
			archive(f, "d0", false)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "D", 2), countIs(f, r, "A", 4))
		}},
		{id: "E36", what: "a mirrored line is edited", apply: func(f *headFix) {
			f.line("cp", "A", 29*time.Minute, lineOpt{from: "AGT-1", fromBox: "box-a", to: "HUM-1", toBox: "box-wui", kind: "result", mirror: "d1"})
			_, err := f.pg.ApplyEdit(ctx, f.tn, f.msg["d1"], f.edit("edited dm answer"))
			f.must("edit", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			if b := bodyOf(f, "cp"); b != "edited dm answer" {
				return "the copy's body is " + b
			}
			return firstOf(countIs(f, r, "A", 4), countIs(f, r, "D", 2))
		}},
		{id: "E37", what: "a channel is unarchived", apply: func(f *headFix) {
			f.must("archive channel", f.pg.ArchiveChannel(ctx, f.tn, "crew", "HUM-1", f.t0))
			f.must("unarchive channel", f.pg.UnarchiveChannel(ctx, f.tn, "crew"))
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "B", 2) }},
		{id: "E38", what: "a topic that has a child is merged", apply: func(f *headFix) {
			_, err := f.pg.MergeTopic(ctx, f.tn, f.msg["a0"], f.task["A"], f.task["B"], "crew", "HUM-1", f.t0)
			f.must("merge", err)
			f.parent = f.task["B"] // parent= now names the child's new parent
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(absent(f, r, "A"), countIs(f, r, "B", 5), parentIs(f, r, "K", "B"))
		}},
		{id: "E39", what: "an archived reply is moved", apply: func(f *headFix) {
			archive(f, "a1", true)
			_, err := f.pg.MoveMessage(ctx, f.tn, f.msg["a1"], f.task["B"], "crew", "HUM-1", f.t0, time.Time{})
			f.must("move", err)
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			return firstOf(countIs(f, r, "A", 2), absent(f, r, "B"))
		}},
		{id: "E40", what: "two lines at the same instant in one topic", apply: func(f *headFix) {
			f.line("e0", "E", 22*time.Minute, lineOpt{card: true, body: "tie lobby"})
			f.line("e1", "E", 22*time.Minute, lineOpt{ch: "crew", from: "AGT-2", fromBox: "box-b", body: "tie crew"})
		}, expect: func(f *headFix, r map[string]TopicRow) string {
			want, ch := "tie lobby", ChannelLobby
			if f.msg["e1"] < f.msg["e0"] {
				want, ch = "tie crew", "crew"
			}
			if c := r[f.task["E"]].Channel; c != ch {
				return "E channel " + c + ", want " + ch
			}
			return firstOf(countIs(f, r, "E", 2), subjectIs(f, r, "E", want))
		}},
		{id: "E41", what: "an insert into a topic whose head rows are deleted", apply: func(f *headFix) {
			dropHeads(f, "A")
			f.line("a3", "A", time.Minute, lineOpt{})
		}, expect: func(f *headFix, r map[string]TopicRow) string { return countIs(f, r, "A", 4) }},
	}
}

// topicHeadShapes is every list shape the hub sends for one case: channel /
// DM / all, roots, the agent and viewer filters, parent=, NoIssues, three
// readers (none = door off, HUM-1 in #crew, HUM-3 in no created channel), and
// the since= delta (TaskIDs) per reader. Small pages, so every case pages.
// The default grid (288 shapes) leaves out agent= without a box and
// noissues= without roots; SPOOL_TEST_LONG=1 runs all 576.
func topicHeadShapes(f *headFix) map[string]TopicQuery {
	out := map[string]TopicQuery{}
	long := os.Getenv("SPOOL_TEST_LONG") == "1"
	readers := []struct {
		id  string
		chs []string
	}{{"", nil}, {"HUM-1", []string{"crew"}}, {"HUM-3", nil}}
	var all []string
	for _, id := range f.task {
		all = append(all, id)
	}
	sort.Strings(all)
	for _, rd := range readers {
		base := TopicQuery{Now: f.now, Lobby: f.task["lobby"], Reader: rd.id, ReaderChannels: rd.chs, Limit: 3}
		for _, where := range []struct {
			ch string
			dm bool
		}{{"", false}, {ChannelLobby, false}, {"crew", false}, {"", true}} {
			for _, roots := range []bool{false, true} {
				for _, ag := range [][2]string{{"", ""}, {"AGT-1", ""}, {"AGT-1", "box-a"}} {
					for _, viewer := range []string{"", "HUM-1"} {
						for _, par := range []string{"", f.parent} {
							for _, noIss := range []bool{false, true} {
								if !long && ((ag[0] != "" && ag[1] == "") || (noIss && !roots)) {
									continue
								}
								q := base
								q.Channel, q.DM, q.Roots, q.Agent, q.AgentBox, q.Viewer, q.Parent, q.NoIssues =
									where.ch, where.dm, roots, ag[0], ag[1], viewer, par, noIss
								out[fmt.Sprintf("reader=%s,ch=%s,dm=%v,roots=%v,agent=%s@%s,viewer=%s,parent=%v,noissues=%v",
									rd.id, where.ch, where.dm, roots, ag[0], ag[1], viewer, par != "", noIss)] = q
							}
						}
					}
				}
			}
		}
		q := base
		q.TaskIDs, q.Limit = all, 0
		out["reader="+rd.id+",task_ids"] = q
	}
	return out
}

// compareAll runs every shape and page of f through the walk, the reference
// and (when set) the head read; it returns the pages compared and the shapes
// that listed at least one topic.
func compareAll(t *testing.T, f *headFix) (pages, nonEmpty int) {
	t.Helper()
	ctx := context.Background()
	for name, q := range topicHeadShapes(f) {
		seen := map[string]bool{}
		for page := 0; ; page++ {
			walk, err := f.pg.ViewTopics(ctx, f.tn, q)
			if err != nil {
				t.Fatalf("%s: walk: %v", name, err)
			}
			ref, err := refTopics(ctx, f.pg, f.tn, q)
			if err != nil {
				t.Fatalf("%s: reference: %v", name, err)
			}
			if d := sameRows(walk, ref); d != "" {
				t.Fatalf("%s page %d: walk != reference: %s", name, page, d)
			}
			if topicHeadRead != nil {
				head, err := topicHeadRead(ctx, f.pg, f.tn, q)
				if err != nil {
					t.Fatalf("%s: head read: %v", name, err)
				}
				if d := sameRows(head, walk); d != "" {
					t.Fatalf("%s page %d: head != walk: %s", name, page, d)
				}
			}
			pages++
			for _, r := range walk {
				if seen[r.TaskID] {
					t.Fatalf("%s: topic %s listed twice across pages", name, r.TaskID)
				}
				seen[r.TaskID] = true
			}
			if q.Limit == 0 || len(walk) < q.Limit {
				break
			}
			last := walk[len(walk)-1]
			q.BeforeAt, q.BeforeTask = last.LastAt, last.TaskID
		}
		if len(seen) > 0 {
			nonEmpty++
		}
	}
	return pages, nonEmpty
}

// headDiffEmpty asserts topic_head_diff(tenant) returns no row; it returns
// false (checks nothing) only where rdb 0144 (T002) is not applied.
func headDiffEmpty(t *testing.T, f *headFix) bool {
	t.Helper()
	ctx := context.Background()
	var fn *string
	if err := f.pg.pool.QueryRow(ctx, `SELECT to_regproc('topic_head_diff')::text`).Scan(&fn); err != nil || fn == nil {
		return false
	}
	var n int
	if err := f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM topic_head_diff($1)`, f.tn).Scan(&n)
	}); err != nil {
		t.Fatalf("topic_head_diff: %v", err)
	}
	if n != 0 {
		t.Fatalf("topic_head_diff: %d topics whose stored head differs from a rebuild", n)
	}
	return true
}

// TestTopicHeadCases is T001's gate: for every case, the walk equals the
// reference on every shape and page, and the case did what it names.
func TestTopicHeadCases(t *testing.T) {
	pg := pgOnly(t)
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	for _, c := range headCases() {
		c := c
		t.Run(c.id, func(t *testing.T) {
			if !c.serial {
				t.Parallel()
			}
			f := seedHeadFix(t, pg, t0)
			c.apply(f)
			plain, err := pg.ViewTopics(context.Background(), f.tn, TopicQuery{Now: f.now, Lobby: f.task["lobby"]})
			if err != nil {
				t.Fatal(err)
			}
			byTask := map[string]TopicRow{}
			for _, r := range plain {
				byTask[r.TaskID] = r
			}
			if msg := c.expect(f, byTask); msg != "" {
				t.Fatalf("%s (%s): the case did not do what it names: %s", c.id, c.what, msg)
			}
			pages, nonEmpty := compareAll(t, f)
			if nonEmpty < 50 {
				t.Fatalf("%s: only %d shapes listed a topic: the fixture does not exercise the filters", c.id, nonEmpty)
			}
			diff := headDiffEmpty(t, f)
			if !diff { // T002: rdb 0144 is in the migrations, so every case checks its heads
				t.Fatalf("%s: topic_head_diff is missing: rdb 0144 not applied", c.id)
			}
			t.Logf("%s %s: %d pages equal, %d non-empty shapes, head diff checked=%v", c.id, c.what, pages, nonEmpty, diff)
		})
	}
}

// refControl breaks one rule of spec section 2 in a copy of the reference:
// every from is replaced by its to. onCase names the case whose fixture can
// fail it ("" = the mixed fixture of controlFix).
type refControl struct {
	name, onCase string
	from, to     string
}

// refControls is spec 7.1's list: the first three caught on T001's mixed
// fixture, the five T001b added each on the one case that can fail it.
var refControls = []refControl{
	{"no door per line (count)", "", "FROM s JOIN d ON d.task_id = s.task_id AND d.door", "FROM s JOIN d ON d.task_id = s.task_id"},
	{"no archived hide", "", "AND NOT EXISTS (SELECT 1 FROM messages z WHERE", "AND NOT EXISTS (SELECT 1 FROM messages z WHERE false AND"},
	{"order key under the door", "", "SELECT task_id, max(received_at) AS last_at", "SELECT task_id, max(received_at) FILTER (WHERE door) AS last_at"},
	{"tie-break ASC", "E28", "ORDER BY t.last_at DESC, t.task_id::text DESC LIMIT $17", "ORDER BY t.last_at DESC, t.task_id::text ASC LIMIT $17"},
	{"cursor ignores the task", "E28", "(t.last_at, t.task_id::text) < ($15::timestamptz, $16::text)", "(t.last_at < $15::timestamptz AND $16::text = $16::text)"},
	{"card rule dropped", "E31", "z.msg_id = t.task_id OR", "false OR"},
	{"agent box ignored", "E32", "($6::text = '' OR", "(true OR"},
	{"first parent under the door", "E33", "(array_agg(parent_task_id::text ORDER BY received_at, msg_id::text))[1] AS first_parent",
		"(array_agg(parent_task_id::text ORDER BY received_at, msg_id::text) FILTER (WHERE door))[1] AS first_parent"},
}

// controlFix is T001's control fixture: the seed plus a mixed channel + DM
// topic and an archived reply.
func controlFix(f *headFix) {
	f.line("m0", "M", 15*time.Minute, lineOpt{card: true, from: "AGT-2", fromBox: "box-b", to: "ALL-0"})
	f.line("m1", "M", 5*time.Minute, lineOpt{ch: "-", from: "HUM-2", fromBox: "box-wui", to: "AGT-2", toBox: "box-b", kind: "note"})
	f.line("w0", "W", 12*time.Minute, lineOpt{card: true})
	f.line("w1", "W", 11*time.Minute, lineOpt{})
	archive(f, "w1", true)
}

// controlCaught pages every shape of f as compareAll does (the walk's
// cursor), comparing the walk with the broken reference on each page; it
// names the first shape and page where they differ, "" if none.
func controlCaught(t *testing.T, f *headFix, broken string) string {
	t.Helper()
	ctx := context.Background()
	names := make([]string, 0, 300)
	shapes := topicHeadShapes(f)
	for n := range shapes {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		q := shapes[name]
		for page := 0; ; page++ {
			walk, err := f.pg.ViewTopics(ctx, f.tn, q)
			if err != nil {
				t.Fatalf("%s: walk: %v", name, err)
			}
			ref, err := refTopicsWith(ctx, f.pg, broken, f.tn, q)
			if err != nil {
				t.Fatalf("%s: broken reference: %v", name, err)
			}
			if d := sameRows(walk, ref); d != "" {
				return fmt.Sprintf("%s page %d: %s", name, page, strings.ReplaceAll(d, "\n", " |"))
			}
			if q.Limit == 0 || len(walk) < q.Limit {
				break
			}
			q.BeforeAt, q.BeforeTask = walk[len(walk)-1].LastAt, walk[len(walk)-1].TaskID
		}
	}
	return ""
}

// TestTopicHeadReferenceControl: the reference must be able to fail. Each
// control breaks one rule of spec section 2 in a copy of the reference and,
// as a hard assertion, the walk then disagrees with it on some shape and
// page of the case that control needs.
func TestTopicHeadReferenceControl(t *testing.T) {
	pg := pgOnly(t)
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	cases := map[string]headCase{}
	for _, c := range headCases() {
		cases[c.id] = c
	}
	for _, rc := range refControls {
		rc := rc
		t.Run(rc.name, func(t *testing.T) {
			t.Parallel()
			if !strings.Contains(refTopicsSQL, rc.from) {
				t.Fatalf("%q not in the reference", rc.from)
			}
			f := seedHeadFix(t, pg, t0)
			if c, ok := cases[rc.onCase]; ok {
				c.apply(f)
			} else if rc.onCase != "" {
				t.Fatalf("no case %s", rc.onCase)
			} else {
				controlFix(f)
			}
			where := controlCaught(t, f, strings.ReplaceAll(refTopicsSQL, rc.from, rc.to))
			if where == "" {
				t.Fatalf("CONTROL %q on %q: a reference with that rule broken still equals the walk on every shape and page", rc.name, rc.onCase)
			}
			t.Logf("control %q on case %q caught: %s", rc.name, rc.onCase, where)
		})
	}
}
