package store

import (
	"context"
	"maps"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// IDFact is what POST /v1/view/ids (HUM-10, topic cd357c76) knows about one
// stored id before the reader's door is applied: an id quoted in a message
// body becomes a link to the place it names, even when the browser tab has
// not loaded that row.
type IDFact struct {
	ID   string // the full uuid
	Kind string // IDTopic or IDMessage
	// TaskID is the topic a link opens: the id itself for a topic, a
	// message's parent task (else its own task) for a message.
	TaskID string
	MsgID  string // a message's id; "" for a topic
	// Channel is a message's channel, or a topic's first channel tag (the
	// topic starter's first); "" = none.
	Channel string
	// Channels are the distinct channel tags of a topic ("" when it holds a
	// DM row); a message's own tag alone.
	Channels []string
	// Parties are the ids at both ends of the DM (untagged) rows.
	Parties []string
	// Ends are one DM row's two ends as the sidebar names a peer: id, or
	// id@box when the row carries a box. For a topic, its earliest DM row.
	Ends     []string
	Archived bool
}

// Kinds of IDFact.
const (
	IDTopic   = "topic"
	IDMessage = "message"
)

// IDLookups is implemented by Memory and Postgres. A hub caller asks for it
// with a type assertion.
type IDLookups interface {
	// LookupIDs returns a fact for each of full (canonical uuids) that is a
	// live topic or message of tenant, and for up to two topics and two
	// messages whose id starts with each of short (8 lowercase hex). A
	// topic id is IDTopic even when a message shares it. The lobby task is
	// never archived as a whole. One round trip.
	LookupIDs(ctx context.Context, tenantID string, full, short []string, now time.Time, lobby string) ([]IDFact, error)
}

var (
	_ IDLookups = (*Memory)(nil)
	_ IDLookups = (*Postgres)(nil)
)

// ---- Memory ---------------------------------------------------------------

func (s *Memory) LookupIDs(_ context.Context, tenant string, full, short []string, now time.Time, lobby string) ([]IDFact, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	live := s.liveLocked(tenant, now)
	want := map[string]bool{}
	for _, id := range full {
		want[id] = true
	}
	for _, tok := range short {
		addShort(live, tok, want)
	}
	var out []IDFact
	topics := map[string]bool{}
	for id := range want {
		if f, ok := memTopicFact(live, id); ok {
			f.Archived = !s.topicStampLocked(tenant, id, lobby).ArchivedAt.IsZero()
			topics[id] = true
			out = append(out, f)
		}
	}
	for _, m := range live {
		if want[m.MsgID] && !topics[m.MsgID] {
			out = append(out, memMessageFact(m, s.archivedRowLocked(tenant, m, lobby)))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// addShort adds up to two topics and two messages starting with tok.
func addShort(live []*Message, tok string, want map[string]bool) {
	tasks, msgs := map[string]bool{}, map[string]bool{}
	for _, m := range live {
		if len(tasks) < 2 && strings.HasPrefix(m.TaskID, tok) {
			tasks[m.TaskID] = true
		}
		if len(msgs) < 2 && strings.HasPrefix(m.MsgID, tok) {
			msgs[m.MsgID] = true
		}
	}
	for id := range tasks {
		want[id] = true
	}
	for id := range msgs {
		want[id] = true
	}
}

// memTopicFact is the topic fact of id, without Archived; false = no live
// row has that task.
func memTopicFact(live []*Message, id string) (IDFact, bool) {
	f := IDFact{ID: id, Kind: IDTopic, TaskID: id}
	chans, parties := map[string]bool{}, map[string]bool{}
	var first, firstDM *Message
	// live is newest first: the last match is the earliest row.
	for _, m := range live {
		if m.TaskID != id {
			continue
		}
		chans[m.Channel] = true
		if m.Channel != "" {
			if first == nil || m.IsParent >= first.IsParent {
				first = m
			}
			continue
		}
		firstDM = m
		parties[m.FromID], parties[m.ToID] = true, true
	}
	if len(chans) == 0 {
		return f, false
	}
	if first != nil {
		f.Channel = first.Channel
	}
	if firstDM != nil {
		f.Ends = []string{sidebarEnd(firstDM.FromID, firstDM.FromBox), sidebarEnd(firstDM.ToID, firstDM.ToBox)}
	}
	f.Channels = sortedKeys(chans)
	f.Parties = dedupSorted(sortedKeys(parties))
	return f, true
}

func memMessageFact(m *Message, archived bool) IDFact {
	f := IDFact{ID: m.MsgID, Kind: IDMessage, TaskID: m.TaskID, MsgID: m.MsgID,
		Channel: m.Channel, Channels: []string{m.Channel}, Archived: archived}
	if m.ParentTaskID != "" {
		f.TaskID = m.ParentTaskID
	}
	if m.Channel == "" {
		f.Parties = dedupSorted([]string{m.FromID, m.ToID})
		f.Ends = []string{sidebarEnd(m.FromID, m.FromBox), sidebarEnd(m.ToID, m.ToBox)}
	}
	return f
}

// archivedRowLocked is archivedHideSQL's rule on one row: its own card,
// its task's card, its task or its parent task (the lobby's excepted) is
// archived.
func (s *Memory) archivedRowLocked(tenant string, a *Message, lobby string) bool {
	for k, z := range s.messages {
		if k[0] != tenant || z.ArchivedAt.IsZero() {
			continue
		}
		if z.MsgID == a.MsgID || z.MsgID == a.TaskID ||
			(z.TaskID == a.TaskID && a.TaskID != lobby) ||
			(a.ParentTaskID != "" && z.TaskID == a.ParentTaskID && a.ParentTaskID != lobby) {
			return true
		}
	}
	return false
}

func sidebarEnd(id, box string) string {
	if box == "" {
		return id
	}
	return id + "@" + box
}

// sortedKeys is the keys of m in ascending order, so a fact built from a map
// reads the same on every call; an empty map gives nil.
func sortedKeys(m map[string]bool) []string {
	return slices.Sorted(maps.Keys(m))
}

// dedupSorted is in without "" and repeats, sorted.
func dedupSorted(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, p := range in {
		if p != "" && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}

// ---- Postgres -------------------------------------------------------------

// lookupIDsSQL: $1 tenant, $2 full uuids, $3 now, $4 lobby, $5 short tokens.
// cand is every id asked for, plus up to two topics and two messages per
// short token, each found by a uuid RANGE on its index (an 8-hex prefix is
// the range [<tok>-0000-..., <tok>-ffff-...]). t aggregates the topics on
// messages_topic_access; the second half is the messages that are not
// topics. The archived tests are topicArchivedSQL's and archivedHideSQL's.
const lookupIDsSQL = `WITH s AS (SELECT
		(x || '-0000-0000-0000-000000000000')::uuid AS lo,
		(x || '-ffff-ffff-ffff-ffffffffffff')::uuid AS hi
		FROM unnest($5::text[]) x),
	cand AS (
		SELECT x::uuid AS id FROM unnest($2::text[]) x
		UNION SELECT c.task_id FROM s CROSS JOIN LATERAL (SELECT DISTINCT m.task_id FROM messages m
			WHERE m.tenant_id = $1 AND m.task_id BETWEEN s.lo AND s.hi AND m.expires_at > $3 LIMIT 2) c
		UNION SELECT c.msg_id FROM s CROSS JOIN LATERAL (SELECT m.msg_id FROM messages m
			WHERE m.tenant_id = $1 AND m.msg_id BETWEEN s.lo AND s.hi AND m.expires_at > $3 LIMIT 2) c),
	t AS (SELECT m.task_id AS id,
		array_agg(DISTINCT COALESCE(m.channel, '')) AS chans,
		COALESCE(array_agg(DISTINCT m.from_id) FILTER (WHERE m.channel IS NULL), '{}')
			|| COALESCE(array_agg(DISTINCT m.to_id) FILTER (WHERE m.channel IS NULL), '{}') AS parties
		FROM messages m JOIN cand ON m.task_id = cand.id
		WHERE m.tenant_id = $1 AND m.expires_at > $3
		GROUP BY m.task_id)
SELECT 'topic', t.id::text, t.id::text, '', COALESCE(f.channel, ''), t.chans, t.parties, COALESCE(d.ends, '{}'),
	EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = $1 AND z.archived_at IS NOT NULL
		AND (z.msg_id = t.id OR (z.task_id = t.id AND t.id::text <> $4::text)))
FROM t
LEFT JOIN LATERAL (SELECT m.channel FROM messages m
	WHERE m.tenant_id = $1 AND m.task_id = t.id AND m.channel IS NOT NULL AND m.expires_at > $3
	ORDER BY m.is_parent DESC, m.received_at, m.msg_id LIMIT 1) f ON true
LEFT JOIN LATERAL (SELECT ` + endsSQL + ` AS ends FROM messages m
	WHERE m.tenant_id = $1 AND m.task_id = t.id AND m.channel IS NULL AND m.expires_at > $3
	ORDER BY m.received_at, m.msg_id LIMIT 1) d ON true
UNION ALL
SELECT 'message', m.msg_id::text, COALESCE(m.parent_task_id, m.task_id)::text, m.msg_id::text,
	COALESCE(m.channel, ''), ARRAY[COALESCE(m.channel, '')],
	CASE WHEN m.channel IS NULL THEN ARRAY[m.from_id, m.to_id] ELSE '{}'::text[] END,
	CASE WHEN m.channel IS NULL THEN ` + endsSQL + ` ELSE '{}'::text[] END,
	EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = $1 AND z.archived_at IS NOT NULL
		AND (z.msg_id = m.msg_id OR z.msg_id = m.task_id
			OR (z.task_id = m.task_id AND m.task_id::text <> $4::text)
			OR (z.task_id = m.parent_task_id AND m.parent_task_id::text <> $4::text)))
FROM messages m JOIN cand ON m.msg_id = cand.id
WHERE m.tenant_id = $1 AND m.expires_at > $3 AND NOT EXISTS (SELECT 1 FROM t WHERE t.id = m.msg_id)`

// endsSQL is sidebarEnd of row m's two ends.
const endsSQL = `ARRAY[m.from_id || CASE WHEN m.from_box <> '' THEN '@' || m.from_box ELSE '' END,
	m.to_id || CASE WHEN m.to_box <> '' THEN '@' || m.to_box ELSE '' END]`

func (s *Postgres) LookupIDs(ctx context.Context, tenant string, full, short []string, now time.Time, lobby string) ([]IDFact, error) {
	if err := checkTenant(tenant); err != nil || (len(full) == 0 && len(short) == 0) {
		return nil, err
	}
	if full == nil {
		full = []string{}
	}
	if short == nil {
		short = []string{}
	}
	var out []IDFact
	err := s.queryTenant(ctx, tenant, lookupIDsSQL, []any{tenant, full, now, lobby, short}, func(r pgx.Rows) error {
		var f IDFact
		if err := r.Scan(&f.Kind, &f.ID, &f.TaskID, &f.MsgID, &f.Channel, &f.Channels, &f.Parties, &f.Ends, &f.Archived); err != nil {
			return err
		}
		sort.Strings(f.Channels)
		f.Parties = dedupSorted(f.Parties)
		out = append(out, f)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}
