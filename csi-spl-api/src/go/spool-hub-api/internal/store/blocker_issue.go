package store

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/jackc/pgx/v5"
)

// An unanswered blocker to a person becomes an issue assigned to them (owner
// HUM-10, topic e48433ef msg 2512ff1f): a message of kind blocker that names
// a person (HUM-n as its recipient or as an @mention), and that person does
// not post in the topic within the workspace's N minutes. The hub's sweep
// (internal/hub/blocker_issue.go) makes the issue; these are its reads.
//
// No migration: N is a registered tenants.settings key (spec 098), and the
// issue's discussion topic id is derived from the blocker and the person
// (BlockerIssueTask), so the existing UNIQUE (tenant_id, task_id) of issues
// (rdb 0047) is the "never a second issue for the same message" key.

// BlockerKeyIssueMinutes is "blocker to issue after N minutes"; 0 = off.
const BlockerKeyIssueMinutes = "blocker.issue_after_minutes"

// The range of N: off, or one minute up to a day.
const (
	BlockerIssueMinutesDefault = 3
	BlockerIssueMinutesMax     = 1440
)

func init() {
	RegisterTenantSetting(TenantSettingDef{Key: BlockerKeyIssueMinutes, Kind: SettingInt,
		Default: BlockerIssueMinutesDefault, Min: 0, Max: BlockerIssueMinutesMax})
}

// BlockerIssueLabel is the label every converted issue carries.
const BlockerIssueLabel = "blocker"

// BlockerPost is one message of kind blocker that may name a person.
type BlockerPost struct {
	MsgID      string
	TaskID     string
	Channel    string // "" = a DM
	FromBox    string
	FromID     string
	ToBox      string
	ToID       string
	Body       string
	ReceivedAt time.Time
}

// RealSender is p as its author wrote it (RCA 8c64225e A1.1): a line one box
// relays to another opens with "from_agent: <id>@<box>" and is sent under a
// seated proxy id of that box (spool-fleet-relay.sh), and the hub keeps that
// body verbatim. The line is dropped and its id and box become FromID and
// FromBox, so the title, the description, created_by and the self-send rule
// of Assignees all see the real sender, never the proxy. A post with no such
// line, or one claiming another box's agent, is returned as it is.
func (p BlockerPost) RealSender() BlockerPost {
	if id, box, rest, ok := spool.FromAgentOf(p.FromID, p.FromBox, p.Body); ok {
		p.FromID, p.FromBox, p.Body = id, box, rest
	}
	return p
}

// AssigneeBox is the box assignee a must answer from: the @box it was tagged
// with, else the recipient's box when a is the recipient agent; "" (any box)
// for a person or an agent tagged with no box.
func (p BlockerPost) AssigneeBox(a string) string {
	id, box, ok := strings.Cut(a, "@")
	switch {
	case IsPersonID(id):
		return ""
	case ok:
		return box
	case id == bareID(p.ToID):
		if _, b, ok := strings.Cut(p.ToID, "@"); ok {
			return b
		}
		return p.ToBox
	}
	return ""
}

// Assignees is everyone the post tags: its recipient first, then its
// @mentions in order, once each. A person (HUM-n) or an agent (owner
// correction, t1 de3c2cf5 msg 26c89f60: "assign that issue to that person or
// that agent"); never the author, a broadcast, the hub or a guest. An id is
// kept as written (an agent may carry its @box); the hub checks it is a
// member or a roster agent before it assigns anything.
func (p BlockerPost) Assignees() []string {
	var out []string
	seen := map[string]bool{bareID(p.FromID): true}
	for _, id := range append(recipientIDs(p.ToID), MentionedIDs(p.Body)...) {
		b := bareID(id)
		if !assignable(b) || seen[b] {
			continue
		}
		seen[b] = true
		out = append(out, id)
	}
	return out
}

// recipientIDs is to as a tag when it has the mention grammar's shape.
func recipientIDs(to string) []string {
	if ids := MentionedIDs("@" + to); len(ids) == 1 && ids[0] == bareID(to) {
		return []string{to}
	}
	return nil
}

// assignable: a mention-grammar id that is not a broadcast, the hub or a guest.
func assignable(id string) bool {
	for _, p := range []string{"ALL-", "HUB-", "GST-"} {
		if strings.HasPrefix(id, p) {
			return false
		}
	}
	return id != ""
}

// IsPersonID: HUM- and digits, the member id form.
func IsPersonID(id string) bool {
	n, ok := strings.CutPrefix(id, "HUM-")
	if !ok || n == "" {
		return false
	}
	for _, c := range n {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// BlockerIssueTask is the discussion topic id of the issue made from blocker
// msgID for assignee: the same pair always gives the same id.
func BlockerIssueTask(tenant, msgID, assignee string) string {
	return uuid.FromSeed("spool-blocker-issue:" + tenant + ":" + msgID + ":" + bareID(assignee))
}

// TopicPost is one message of a topic: the reply that answers a blocker.
type TopicPost struct {
	MsgID      string
	FromID     string
	Body       string
	ReceivedAt time.Time
}

// AnswerQuery is who must answer a blocker, and where (RCA 8c64225e A1.2,
// C1.3). A post answers when its real author (its from_agent line checked
// against its from_box, else from_id and from_box) is ID, and:
//   - Box: it came from Box ("" = any box). A post by the same id from
//     another box answers only when it references the blocker: the role ids
//     (c-001 orchestrator, c-002 dispatch) move between boxes on a lease
//     rotation, and a reference proves the new holder answers THIS blocker,
//     while the same bare id on the other box without one is a different
//     seat (measured: SPL-1588, SPL-2769).
//   - Ref: when the topic holds any other message that is or was a blocker,
//     the post must reference Ref, the blocker's msg_id: its first 8 hex
//     ("re 09824eb5", "accepts 09824eb5") or the whole id. One shared alarm
//     topic holds every alarm of its name, so an answer to the newest one,
//     or a status card, must not resolve the older ones (SPL-1588, 2769,
//     3244, 3901, 4360).
type AnswerQuery struct {
	Task string
	ID   string
	Box  string
	Ref  string // the blocker's msg_id; "" = no reference rule
	At   time.Time
}

// answerScan bounds the posts of a topic one answer lookup reads.
const answerScan = 200

// answers: post (from, fromBox, body) is an answer to q; shared = the topic
// holds another blocker.
func (q AnswerQuery) answers(from, fromBox, body string, shared bool) bool {
	id, box, _, ok := spool.FromAgentOf(from, fromBox, body)
	if !ok {
		id, box = from, fromBox
		if i, b, at := strings.Cut(from, "@"); at {
			id, box = i, b
		}
	}
	if id != bareID(q.ID) {
		return false
	}
	ref := q.Ref != "" && References(body, q.Ref)
	if shared && !ref {
		return false
	}
	return q.Box == "" || box == q.Box || ref
}

// References: body names msgID by its first 8 hex digits as a word, or whole.
func References(body, msgID string) bool {
	if len(msgID) < 8 {
		return false
	}
	b, short := strings.ToLower(body), strings.ToLower(msgID[:8])
	for i := 0; ; {
		j := strings.Index(b[i:], short)
		if j < 0 {
			return false
		}
		j += i
		if (j == 0 || !isHexWord(b[j-1])) && (j+8 == len(b) || !isHexWord(b[j+8]) || b[j+8] == '-') {
			return true
		}
		i = j + 1
	}
}

// isHexWord: c continues a hex token (a digit, a letter, or the uuid dash).
func isHexWord(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c == '-' || c == '_'
}

// BlockerIssues is what the blocker sweep reads. Postgres and Memory.
type BlockerIssues interface {
	// BlockerTenants lists every workspace that is neither suspended nor
	// archived (one operator read), in id order.
	BlockerTenants(ctx context.Context) ([]string, error)
	// BlockerPosts lists the tenant's live (not archived) kind=blocker
	// messages received in [since, until), oldest first, at most limit.
	BlockerPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]BlockerPost, error)
	// FirstPostAfter is from's first post in task after at, matched on the
	// real author's bare id (c-002 and c-002@<box> are one agent), from any
	// box; ok false when none. BlockerAnswer with no box and no reference.
	FirstPostAfter(ctx context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error)
	// BlockerAnswer is the first post in q.Task after q.At that answers the
	// blocker (AnswerQuery); ok false when none. One read of
	// messages_task_received, with no window: the long tick re-checks open
	// issues of any age with it (RCA 8c64225e C1.2).
	BlockerAnswer(ctx context.Context, tenant string, q AnswerQuery) (TopicPost, bool, error)
	// IssueByTask is the tenant's issue on task, live or not (Status ""
	// when it is deleted or archived); ErrNotFound when none ever was.
	IssueByTask(ctx context.Context, tenant, task string) (BlockerIssueRef, error)
}

// BlockerIssueRef is what the sweep needs of an issue: its number, and its
// status while it is live ("" once it is deleted or archived).
type BlockerIssueRef struct {
	Number int
	Status string
}

var (
	_ BlockerIssues = (*Memory)(nil)
	_ BlockerIssues = (*Postgres)(nil)
)

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) BlockerTenants(ctx context.Context) ([]string, error) {
	out := []string{}
	err := s.asOperatorQuery(ctx, `SELECT tenant_id FROM tenants
		WHERE suspended_at IS NULL AND archived_at IS NULL ORDER BY tenant_id`, nil, func(r pgx.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		out = append(out, id)
		return nil
	})
	return out, err
}

// BlockerPosts walks messages_received (tenant_id, received_at) over the
// window; the kind filters the rows it reads.
func (s *Postgres) BlockerPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]BlockerPost, error) {
	var out []BlockerPost
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, task_id::text, COALESCE(channel, ''), from_box, from_id, to_box, to_id, body, received_at
		FROM messages
		WHERE tenant_id = $1 AND received_at >= $2 AND received_at < $3
		  AND kind = 'blocker' AND archived_at IS NULL
		ORDER BY received_at, msg_id LIMIT $4`, []any{tenant, since, until, limit},
		func(rows pgx.Rows) error {
			var p BlockerPost
			if err := rows.Scan(&p.MsgID, &p.TaskID, &p.Channel, &p.FromBox, &p.FromID, &p.ToBox, &p.ToID, &p.Body, &p.ReceivedAt); err != nil {
				return err
			}
			out = append(out, p.RealSender())
			return nil
		})
	return out, err
}

// FirstPostAfter is one probe of messages_task_received: BlockerAnswer
// with no box and no reference.
func (s *Postgres) FirstPostAfter(ctx context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error) {
	return s.BlockerAnswer(ctx, tenant, AnswerQuery{Task: task, ID: from, At: at})
}

// BlockerAnswer reads the topic's posts after q.At on messages_task_received
// that may be the id's: its own rows, and relayed rows naming it in the
// from_agent line (any proxy); answers then checks each one.
func (s *Postgres) BlockerAnswer(ctx context.Context, tenant string, q AnswerQuery) (TopicPost, bool, error) {
	shared, err := s.otherBlocker(ctx, tenant, q)
	if err != nil {
		return TopicPost{}, false, err
	}
	var p TopicPost
	found := false
	id := bareID(q.ID)
	err = s.queryTenant(ctx, tenant, `SELECT msg_id::text, from_id, from_box, body, received_at FROM messages
		WHERE tenant_id = $1 AND task_id = $2 AND received_at > $3
		  AND (from_id = $4 OR from_id LIKE $4 || '@%' OR starts_with(body, $5))
		ORDER BY received_at, msg_id LIMIT $6`,
		[]any{tenant, q.Task, q.At, id, spool.FromAgentPrefix + id + "@", answerScan}, func(rows pgx.Rows) error {
			var c TopicPost
			var box string
			if err := rows.Scan(&c.MsgID, &c.FromID, &box, &c.Body, &c.ReceivedAt); err != nil {
				return err
			}
			if !found && q.answers(c.FromID, box, c.Body, shared) {
				p, found = c, true
			}
			return nil
		})
	return p, found, err
}

// otherBlocker: q.Task holds a message other than q.Ref that is a blocker,
// or was one (message_kind_changes, rdb 0060), so the reference is required.
func (s *Postgres) otherBlocker(ctx context.Context, tenant string, q AnswerQuery) (bool, error) {
	if q.Ref == "" {
		return false, nil
	}
	shared := false
	err := s.queryTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages m
		WHERE m.tenant_id = $1 AND m.task_id = $2 AND m.msg_id <> $3::uuid
		  AND (m.kind = 'blocker' OR EXISTS (SELECT 1 FROM message_kind_changes k
			WHERE k.tenant_id = m.tenant_id AND k.msg_id = m.msg_id
			  AND (k.kind_from = 'blocker' OR k.kind_to = 'blocker'))))`,
		[]any{tenant, q.Task, q.Ref}, func(rows pgx.Rows) error {
			return rows.Scan(&shared)
		})
	return shared, err
}

func (s *Postgres) IssueByTask(ctx context.Context, tenant, task string) (BlockerIssueRef, error) {
	var r BlockerIssueRef
	found := false
	err := s.queryTenant(ctx, tenant, `SELECT number,
			CASE WHEN deleted_at IS NULL AND archived_at IS NULL THEN status ELSE '' END
		FROM issues WHERE tenant_id = $1 AND task_id = $2`, []any{tenant, task},
		func(rows pgx.Rows) error {
			found = true
			return rows.Scan(&r.Number, &r.Status)
		})
	if err == nil && !found {
		err = ErrNotFound
	}
	return r, err
}

// ---- Memory -----------------------------------------------------------------

func (s *Memory) BlockerTenants(_ context.Context) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for id, t := range s.tenants {
		if t.SuspendedAt.IsZero() && t.ArchivedAt.IsZero() {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out, nil
}

func (s *Memory) BlockerPosts(_ context.Context, tenant string, since, until time.Time, limit int) ([]BlockerPost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []BlockerPost
	for k, m := range s.messages {
		if k[0] != tenant || m.Kind != "blocker" || !m.ArchivedAt.IsZero() ||
			m.ReceivedAt.Before(since) || !m.ReceivedAt.Before(until) {
			continue
		}
		out = append(out, BlockerPost{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, FromBox: m.FromBox,
			FromID: m.FromID, ToBox: m.ToBox, ToID: m.ToID, Body: m.Body, ReceivedAt: m.ReceivedAt}.RealSender())
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ReceivedAt.Equal(out[j].ReceivedAt) {
			return out[i].ReceivedAt.Before(out[j].ReceivedAt)
		}
		return out[i].MsgID < out[j].MsgID
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *Memory) FirstPostAfter(ctx context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error) {
	return s.BlockerAnswer(ctx, tenant, AnswerQuery{Task: task, ID: from, At: at})
}

// BlockerAnswer is Postgres.BlockerAnswer over the in-memory rows.
func (s *Memory) BlockerAnswer(_ context.Context, tenant string, q AnswerQuery) (TopicPost, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	shared := q.Ref != "" && s.otherBlockerLocked(tenant, q)
	var best *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != q.Task || !m.ReceivedAt.After(q.At) || !q.answers(m.FromID, m.FromBox, m.Body, shared) {
			continue
		}
		if best == nil || m.ReceivedAt.Before(best.ReceivedAt) || m.ReceivedAt.Equal(best.ReceivedAt) && m.MsgID < best.MsgID {
			best = m
		}
	}
	if best == nil {
		return TopicPost{}, false, nil
	}
	return TopicPost{MsgID: best.MsgID, FromID: best.FromID, Body: best.Body, ReceivedAt: best.ReceivedAt}, true, nil
}

// otherBlockerLocked is Postgres.otherBlocker; s.mu is held.
func (s *Memory) otherBlockerLocked(tenant string, q AnswerQuery) bool {
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != q.Task || m.MsgID == q.Ref {
			continue
		}
		if m.Kind == "blocker" {
			return true
		}
		for _, c := range s.kindChanges[k] {
			if c.From == "blocker" || c.To == "blocker" {
				return true
			}
		}
	}
	return false
}

func (s *Memory) IssueByTask(_ context.Context, tenant, task string) (BlockerIssueRef, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	for n, r := range s.iss.rows[tenant] {
		if r.TaskID == task {
			return BlockerIssueRef{Number: n, Status: r.Status}, nil
		}
	}
	for _, rows := range []map[int]Issue{s.iss.gone[tenant], s.iss.archived[tenant]} {
		for n, r := range rows {
			if r.TaskID == task {
				return BlockerIssueRef{Number: n}, nil
			}
		}
	}
	return BlockerIssueRef{}, ErrNotFound
}
