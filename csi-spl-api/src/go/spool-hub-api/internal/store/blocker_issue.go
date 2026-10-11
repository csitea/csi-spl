package store

import (
	"context"
	"sort"
	"strings"
	"time"

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
	FromID     string
	ToID       string
	Body       string
	ReceivedAt time.Time
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

// BlockerIssues is what the blocker sweep reads. Postgres and Memory.
type BlockerIssues interface {
	// BlockerTenants lists every workspace that is neither suspended nor
	// archived (one operator read), in id order.
	BlockerTenants(ctx context.Context) ([]string, error)
	// BlockerPosts lists the tenant's live (not archived) kind=blocker
	// messages received in [since, until), oldest first, at most limit.
	BlockerPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]BlockerPost, error)
	// FirstPostAfter is from's first post in task after at, matched on the
	// bare id (c-002 and c-002@<box> are one agent); ok false when none.
	FirstPostAfter(ctx context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error)
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
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, task_id::text, COALESCE(channel, ''), from_id, to_id, body, received_at
		FROM messages
		WHERE tenant_id = $1 AND received_at >= $2 AND received_at < $3
		  AND kind = 'blocker' AND archived_at IS NULL
		ORDER BY received_at, msg_id LIMIT $4`, []any{tenant, since, until, limit},
		func(rows pgx.Rows) error {
			var p BlockerPost
			if err := rows.Scan(&p.MsgID, &p.TaskID, &p.Channel, &p.FromID, &p.ToID, &p.Body, &p.ReceivedAt); err != nil {
				return err
			}
			out = append(out, p)
			return nil
		})
	return out, err
}

// FirstPostAfter is one probe of messages_task_received.
func (s *Postgres) FirstPostAfter(ctx context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error) {
	var p TopicPost
	found := false
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, from_id, body, received_at FROM messages
		WHERE tenant_id = $1 AND task_id = $2 AND received_at > $3
		  AND (from_id = $4 OR from_id LIKE $4 || '@%')
		ORDER BY received_at, msg_id LIMIT 1`,
		[]any{tenant, task, at, bareID(from)}, func(rows pgx.Rows) error {
			found = true
			return rows.Scan(&p.MsgID, &p.FromID, &p.Body, &p.ReceivedAt)
		})
	return p, found, err
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
		out = append(out, BlockerPost{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel,
			FromID: m.FromID, ToID: m.ToID, Body: m.Body, ReceivedAt: m.ReceivedAt})
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

func (s *Memory) FirstPostAfter(_ context.Context, tenant, task, from string, at time.Time) (TopicPost, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != task || !m.ReceivedAt.After(at) || bareID(m.FromID) != bareID(from) {
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
