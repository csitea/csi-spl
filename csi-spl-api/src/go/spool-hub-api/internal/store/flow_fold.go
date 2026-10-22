package store

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The folded Flow (spec 130 section 2): "a condensed answer to the question
// 'What is happening?'" (owner, t1 da98036e). A member's events in one topic
// on one UTC day are ONE line, and the releases of one UTC day are one line.
// The fold reads the member's newest FlowFoldWindow events and keeps the
// first lines; the cursor stays the raw (at, msg_id) of the oldest event a
// kept line holds, so the next page folds the next window and a group cut by
// the window edge shows as two lines.

const (
	// FlowFoldWindow is how many raw events one folded page reads at most
	// (the WUI's FLOW_CAP, spec 130 section 2.6).
	FlowFoldWindow = 200
	// FlowReleaseSpan is how far back the release lines of the last page
	// reach: with no older event to page to, the Flow shows a month of releases.
	FlowReleaseSpan = 30 * 24 * time.Hour
)

// flowRank is the strength of a line kind: lower is stronger (spec 130
// section 2.1: blocked, ready, mention, poke, dm, reply).
func flowRank(kind string) int {
	if i := slices.Index(flowLineKinds, kind); i >= 0 {
		return i
	}
	if i := slices.Index(flowKinds, kind); i >= 0 {
		return len(flowLineKinds) + i
	}
	return len(flowLineKinds) + len(flowKinds)
}

// FlowLine is one folded line. A topic line: Kind is the strongest kind of
// the day, Count the events, From the authors newest first (each once), the
// newest event's MsgID / At / Text, the topic's Title (its first message)
// and Issue (the topic's issue number, 0 = none), Unread when any event is.
// A release line (Kind FlowRelease): the day's version span VersionFrom ..
// VersionTo, Versions the count, SHA the newest version's newest commit.
type FlowLine struct {
	Kind         string
	Day          string // YYYY-MM-DD, UTC
	Count        int
	At           time.Time
	TaskID       string
	MsgID        string
	Channel      string
	ParentTaskID string
	From         []string
	Title        string
	Issue        int
	Text         string
	Unread       bool
	VersionFrom  string
	VersionTo    string
	Versions     int
	SHA          string
}

// flowFoldEvent is one raw event of the window: the entry, the event's own
// time (the cursor clock, flow_events.at) and its topic's title and issue.
type flowFoldEvent struct {
	FlowEvent
	evAt  time.Time
	title string
	issue int
}

// flowDay is t's UTC calendar day.
func flowDay(t time.Time) string { return t.UTC().Format(time.DateOnly) }

// foldFlow folds window (newest first, at most FlowFoldWindow+1 events) into
// at most lines lines. It keeps every event before the first event of the
// (lines+1)th group and of the first FlowFoldWindow; more is whether an
// event was left, and last is the oldest kept event (the next cursor).
func foldFlow(window []flowFoldEvent, lines int) (out []FlowLine, last *flowFoldEvent, more bool) {
	at := map[[2]string]int{}
	for i := range window {
		if i == FlowFoldWindow {
			return out, last, true
		}
		e := &window[i]
		k := [2]string{e.TaskID, flowDay(e.evAt)}
		j, ok := at[k]
		if !ok {
			if len(out) == lines {
				return out, last, true
			}
			j, at[k] = len(out), len(out)
			out = append(out, FlowLine{Kind: e.Kind, Day: k[1], At: e.At, TaskID: e.TaskID, MsgID: e.MsgID,
				Channel: e.Channel, ParentTaskID: e.ParentTaskID, Title: e.title, Issue: e.issue, Text: e.Body})
		}
		l := &out[j]
		l.Count++
		l.Unread = l.Unread || e.Unread
		if flowRank(e.Kind) < flowRank(l.Kind) {
			l.Kind = e.Kind
		}
		if !slices.Contains(l.From, e.FromID) {
			l.From = append(l.From, e.FromID)
		}
		last = e
	}
	return out, last, false
}

// flowRelease is one release_notes row the Flow merges: a version reached
// this hub at released_at.
type flowRelease struct {
	version, sha string
	at           time.Time
}

// foldReleases folds rows (newest released first) into one line per UTC
// day, newest day first, at most lines of them. unread says whether a line
// whose newest version is v is unread.
func foldReleases(rows []flowRelease, lines int, unread func(newest time.Time, version string) bool) []FlowLine {
	var out []FlowLine
	seen := map[string]map[string]bool{}
	for _, r := range rows {
		day := flowDay(r.at)
		if len(out) == 0 || out[len(out)-1].Day != day {
			if len(out) == lines {
				break
			}
			out = append(out, FlowLine{Kind: FlowRelease, Day: day, At: r.at, VersionTo: r.version, VersionFrom: r.version, SHA: r.sha})
			seen[day] = map[string]bool{}
		}
		l := &out[len(out)-1]
		if !seen[day][r.version] {
			seen[day][r.version] = true
			l.Versions++
		}
		if releaseNewer(r.version, l.VersionTo) {
			l.VersionTo, l.SHA = r.version, r.sha
		}
		if releaseNewer(l.VersionFrom, r.version) {
			l.VersionFrom = r.version
		}
	}
	for i := range out {
		out[i].Count = out[i].Versions
		out[i].Unread = unread(out[i].At, out[i].VersionTo)
	}
	return out
}

// releaseNewer: version a is newer than b by the release key.
func releaseNewer(a, b string) bool {
	ka, _ := releaseVersionKey(a)
	kb, _ := releaseVersionKey(b)
	return slices.Compare(ka[:], kb[:]) > 0
}

// FlowReleaseMarkKey is the read_marks key of an opened release line: its
// newest version (spec 130 section 2.5, admitted by rdb 0104's CHECK).
func FlowReleaseMarkKey(version string) string { return "f:rel:" + version }

// flowReleaseBounds is the released_at range [from, to) of the release lines
// a page shows: below the page's own cursor, down to the oldest kept event
// when there is a next page, else FlowReleaseSpan back from now.
func flowReleaseBounds(q FlowQuery, last *flowFoldEvent, more bool) (from, to time.Time) {
	to = q.Now
	if q.BeforeID != "" {
		to = q.BeforeAt
	}
	from = q.Now.Add(-FlowReleaseSpan)
	if more && last != nil {
		from = last.evAt
	}
	return from, to
}

// mergeFlowLines merges the release lines into the topic lines, newest first.
func mergeFlowLines(topics, releases []FlowLine) []FlowLine {
	out := append(append(make([]FlowLine, 0, len(topics)+len(releases)), topics...), releases...)
	slices.SortStableFunc(out, func(a, b FlowLine) int { return b.At.Compare(a.At) })
	return out
}

// FlowFold is the folded page: the lines, the cursor of the next page ("" =
// none), and the member's counts.
type FlowFold struct {
	Lines          []FlowLine
	More           bool
	NextAt         time.Time
	NextID         string
	Counts, Unread FlowCounts
	Keys           map[string]int
}

// FlowFolder reads the folded Flow (spec 130). q.Limit is the topic lines.
type FlowFolder interface {
	FlowFoldRead(ctx context.Context, q FlowQuery) (FlowFold, error)
}

var (
	_ FlowFolder = (*Memory)(nil)
	_ FlowFolder = (*Postgres)(nil)
)

// finishFold turns a window and its release rows into the page. kind=
// release reads no events; any other kind filter reads no releases.
func finishFold(q FlowQuery, window []flowFoldEvent, releases func(from, to time.Time) ([]FlowLine, error)) (FlowFold, error) {
	var f FlowFold
	topics, last, more := foldFlow(window, q.Limit)
	var rel []FlowLine
	if q.Kind == "" || q.Kind == FlowRelease {
		from, to := flowReleaseBounds(q, last, more)
		var err error
		if rel, err = releases(from, to); err != nil {
			return f, err
		}
	}
	f.Lines, f.More = mergeFlowLines(topics, rel), more
	if more && last != nil {
		f.NextAt, f.NextID = last.evAt, last.MsgID
	}
	return f, nil
}

// Memory side.

func (s *Memory) FlowFoldRead(_ context.Context, q FlowQuery) (FlowFold, error) {
	s.mu.Lock()
	all := s.flowListLocked(q.Tenant, q.Member, q.Now, q.Lobby)
	counts, unread, keys := s.flowCountsLocked(q.Tenant, q.Member, all, q.Now, q.Lobby)
	var window []flowFoldEvent
	for _, ev := range all {
		if q.Kind == FlowRelease || len(window) > FlowFoldWindow {
			break
		}
		if !flowKindMatch(q.Kind, ev.Kind) || q.BeforeID != "" && !newer(q.BeforeAt, q.BeforeID, ev.At, ev.MsgID) {
			continue
		}
		title, issue := s.flowTopicLocked(q.Tenant, ev.TaskID)
		window = append(window, flowFoldEvent{FlowEvent: ev, evAt: ev.At, title: title, issue: issue})
	}
	seen, hasSeen := s.readMarks[[3]string{q.Tenant, q.Member, FlowSeenKey}]
	relMarks := map[string]bool{}
	for k := range s.readMarks {
		if k[0] == q.Tenant && k[1] == q.Member && strings.HasPrefix(k[2], FlowReleaseMarkKey("")) {
			relMarks[k[2]] = true
		}
	}
	marked := func(version string) bool { return relMarks[FlowReleaseMarkKey(version)] }
	s.mu.Unlock()
	f, err := finishFold(q, window, func(from, to time.Time) ([]FlowLine, error) {
		return foldReleases(s.flowReleases(from, to), q.Limit, func(newest time.Time, v string) bool {
			return (!hasSeen || newest.After(seen.At)) && !marked(v)
		}), nil
	})
	f.Counts, f.Unread, f.Keys = counts, unread, keys
	return f, err
}

// flowTopicLocked is a topic's title (its first message's body) and issue
// number (0 = none).
func (s *Memory) flowTopicLocked(tenant, task string) (string, int) {
	var first *Message
	for k, m := range s.messages {
		if k[0] == tenant && m.TaskID == task && (first == nil || newer(first.ReceivedAt, first.MsgID, m.ReceivedAt, m.MsgID)) {
			first = m
		}
	}
	title := ""
	if first != nil {
		title = first.Body
	}
	s.iss.init()
	for n, r := range s.iss.rows[tenant] {
		if r.TaskID == task {
			return title, n
		}
	}
	return title, 0
}

// flowReleases is the versioned release rows released in [from, to),
// newest first.
func (s *Memory) flowReleases(from, to time.Time) []flowRelease {
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	var out []flowRelease
	for sha, at := range memReleased[s] {
		if !at.Before(from) && at.Before(to) {
			out = append(out, flowRelease{version: s.releases()[sha].Version, sha: sha, at: at})
		}
	}
	slices.SortFunc(out, func(a, b flowRelease) int {
		if c := b.at.Compare(a.at); c != 0 {
			return c
		}
		return strings.Compare(b.sha, a.sha)
	})
	return out
}

// Postgres side.

// flowFoldSQL is the window: the member's newest events past the cursor
// ($6, $7) of kind $8 whose message the member may read, $5 of them, each with
// its topic's title (its first message) and issue number, looked up once per
// topic of the window.
//
// The page is cut on flow_events alone first (perf round 5, P5-11): ev is the
// member's newest $5 events, a walk of flow_events_member_at that stops at $5,
// and only those events probe messages for the door. Joining messages before
// the LIMIT let the planner probe every event of the member: on prd its
// RLS predicate hid a member's 6 633 events behind an estimate of 29, and the
// page cost 2.1 s cold. When the door drops some of ev, fill takes the next
// events past ev in the old join shape, so a page never comes back short; its
// guard is an initplan, so a page with no door miss never runs it.
func flowFoldSQL() string {
	evWhere := `e.tenant_id = $1 AND e.member_id = $2 AND e.expires_at > $3
			  AND ($6::timestamptz IS NULL OR (e.at, e.msg_id) < ($6::timestamptz, $7::uuid))
			  AND ($8::text[] IS NULL OR e.kind = ANY($8::text[]))`
	return `WITH ev AS (SELECT e.tenant_id, e.member_id, e.msg_id, e.kind, e.at FROM flow_events e
			WHERE ` + evWhere + `
			ORDER BY e.at DESC, e.msg_id DESC LIMIT $5),
		hit AS (SELECT e.tenant_id, e.member_id, e.msg_id, e.kind, e.at FROM ev e WHERE EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id
			AND m.expires_at > $3` + flowDoorSQL("e", "m", "$4::text[]") + `)),
		fill AS (SELECT e.tenant_id, e.member_id, e.msg_id, e.kind, e.at
			FROM flow_events e JOIN messages m ON m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id
			WHERE ` + evWhere + ` AND m.expires_at > $3` + flowDoorSQL("e", "m", "$4::text[]") + `
			  AND (SELECT count(*) FROM hit) < (SELECT count(*) FROM ev) AND (SELECT count(*) FROM ev) = $5
			  AND (e.at, e.msg_id) < (SELECT x.at, x.msg_id FROM ev x ORDER BY x.at, x.msg_id LIMIT 1)
			ORDER BY e.at DESC, e.msg_id DESC LIMIT $5),
		raw AS (SELECT ` + flowEventCols("e", "m", "$3", "$9::text") + `, e.at AS ev_at
			FROM (SELECT h.tenant_id, h.member_id, h.msg_id, h.kind, h.at FROM hit h
				UNION ALL SELECT f.tenant_id, f.member_id, f.msg_id, f.kind, f.at FROM fill f
				ORDER BY at DESC, msg_id DESC LIMIT $5) e
			JOIN messages m ON m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id),
		tt AS (SELECT d.task_id,
				coalesce((SELECT left(r.body, 400) FROM messages r WHERE r.tenant_id = $1 AND r.task_id = d.task_id::uuid
					ORDER BY r.received_at, r.msg_id LIMIT 1), '') AS title,
				coalesce((SELECT i.number FROM issues i WHERE i.tenant_id = $1 AND i.task_id = d.task_id::uuid), 0) AS issue
			FROM (SELECT DISTINCT task_id FROM raw) d)
		SELECT raw.*, tt.title, tt.issue FROM raw JOIN tt ON tt.task_id = raw.task_id ORDER BY raw.ev_at DESC, raw.msg_id DESC`
}

// flowReleasesSQL is the versioned rows released in [$1, $2), newest first
// (rdb 0177's release_notes_released_at), and whether member $4 of tenant
// $3 opened the line of each version (f:rel:<version>) and its f:seen.
const flowReleasesSQL = `SELECT r.version, r.sha, r.released_at,
		EXISTS (SELECT 1 FROM read_marks k WHERE k.tenant_id = $3 AND k.member_id = $4 AND k.mark_key = 'f:rel:' || r.version),
		coalesce((SELECT s.at FROM read_marks s WHERE s.tenant_id = $3 AND s.member_id = $4 AND s.mark_key = 'f:seen'), 'epoch'::timestamptz)
	FROM release_notes r
	WHERE r.released_at IS NOT NULL AND r.version IS NOT NULL AND r.released_at >= $1 AND r.released_at < $2
	ORDER BY r.released_at DESC, r.sha DESC`

func (s *Postgres) FlowFoldRead(ctx context.Context, q FlowQuery) (FlowFold, error) {
	var counts, unread FlowCounts
	var keys map[string]int
	var window []flowFoldEvent
	var before, beforeID any
	if q.BeforeID != "" {
		before, beforeID = q.BeforeAt, q.BeforeID
	}
	reads := []tenantRead{{
		sql:  flowCountsSQL("$1", "$2", "$3", "$4::text[]", "$5::text"),
		args: []any{q.Tenant, q.Member, q.Now, PublicChannels, q.Lobby},
		each: func(r pgx.Rows) (err error) { counts, unread, keys, err = scanFlowCounts(r); return err },
	}}
	if q.Kind != FlowRelease {
		reads = append(reads, tenantRead{
			sql:  flowFoldSQL(),
			args: []any{q.Tenant, q.Member, q.Now, PublicChannels, FlowFoldWindow + 1, before, beforeID, flowKindsFilter(q.Kind), q.Lobby},
			each: func(r pgx.Rows) error {
				var e flowFoldEvent
				ev, err := scanFlowEvent(r, &e.evAt, &e.title, &e.issue)
				e.FlowEvent = ev
				window = append(window, e)
				return err
			},
		})
	}
	if err := s.queryTenantBatch(ctx, q.Tenant, reads...); err != nil {
		return FlowFold{}, err
	}
	f, err := finishFold(q, window, func(from, to time.Time) ([]FlowLine, error) {
		var rows []flowRelease
		marked := map[string]bool{}
		var seen time.Time
		err := s.queryTenant(ctx, q.Tenant, flowReleasesSQL, []any{from, to, q.Tenant, q.Member}, func(r pgx.Rows) error {
			var x flowRelease
			var m bool
			if err := r.Scan(&x.version, &x.sha, &x.at, &m, &seen); err != nil {
				return err
			}
			x.at = x.at.UTC()
			marked[x.version] = m
			rows = append(rows, x)
			return nil
		})
		return foldReleases(rows, q.Limit, func(newest time.Time, v string) bool {
			return newest.After(seen) && !marked[v]
		}), err
	})
	f.Counts, f.Unread, f.Keys = counts, unread, keys
	return f, err
}
