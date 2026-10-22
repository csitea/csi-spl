package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Every issue links to one or more discussions (rdb 0194, SPL-1593). The
// owner (HUM-10, t1 fcf09921): "Issues must be linked to one or more
// discussions." (msg 3e75e13e) "that link in the database should be
// enforced" (msg 62f96f94). A discussion is a topic: the task_id its
// messages share. The database refuses an issue with no link at COMMIT and
// relinks an issue whose last discussion is deleted physically to its
// tenant's default (IssueDiscussionDefault).

// IssueDiscussionsMax is the most discussions one issue links to.
const IssueDiscussionsMax = 20

// The states of a linked discussion as a reader sees it.
const (
	DiscussionLive     = "live"
	DiscussionArchived = "archived" // still opens (owner msg 28b479fd)
	DiscussionGone     = "gone"     // no message left: the link opens the "no longer exists" page
)

// IssueDiscussionDefaultT1 is t1's default discussion: the owner's topic
// (msg 62f96f94, "For all of the existing issues, they could link to this
// discussion").
const IssueDiscussionDefaultT1 = "fcf09921-8f21-4518-a117-f8ddb41bfff5"

// IssueBacklogBody is the "Issue backlog" topic the hub posts in a tenant
// other than t1 (owner msg e3c349e2, "A").
const IssueBacklogBody = "**Issue backlog**\n\n" +
	"The discussion every issue of this workspace links to when it has no other: " +
	"the issues that existed before issues had to link to a discussion, " +
	"and any issue whose last discussion was deleted."

// ErrIssueDiscussionLast refuses removing an issue's last discussion.
var ErrIssueDiscussionLast = errors.New("an issue keeps at least one discussion")

// IssueBacklogID is the "Issue backlog" topic's msg_id (and task_id) in
// tenant: the first 128 bits of sha256("spool-issue-backlog:" + tenant) as a
// uuid, as rdb 0194 spool_issue_backlog_id computes it.
func IssueBacklogID(tenant string) string {
	h := sha256.Sum256([]byte("spool-issue-backlog:" + tenant))
	x := hex.EncodeToString(h[:])
	return x[0:8] + "-" + x[8:12] + "-" + x[12:16] + "-" + x[16:20] + "-" + x[20:32]
}

// IssueDiscussionDefault is what an issue with no other discussion links to,
// the twin of rdb 0194 issue_discussion_default: t1 the owner's topic, every
// other tenant its "Issue backlog" topic.
func IssueDiscussionDefault(tenant string) string {
	if tenant == "t1" {
		return IssueDiscussionDefaultT1
	}
	return IssueBacklogID(tenant)
}

// IssueDiscussion is one link. State, Title and Channel are filled only by
// IssueDiscussionStates.
type IssueDiscussion struct {
	TaskID   string
	LinkedBy string
	LinkedAt time.Time
}

// DiscussionState is what a topic is now: State one of the Discussion*
// constants, Channel its channel ("" for a DM or a gone topic), Title the
// first line of its opening message (the caller decides who may see it).
type DiscussionState struct {
	State, Channel, Title string
}

// IssueDiscussions is the store side of rdb 0194.
type IssueDiscussions interface {
	// IssueDiscussionLinks is every link of the given issues (nil: every
	// issue of the tenant), oldest link first.
	IssueDiscussionLinks(ctx context.Context, tenant string, numbers []int) (map[int][]IssueDiscussion, error)
	// DiscussionStates reads what each topic is now.
	DiscussionStates(ctx context.Context, tenant string, tasks []string) (map[string]DiscussionState, error)
	// LinkIssueDiscussion adds one link; a second add of the same link is a
	// no-op (added false). ErrNotFound for no such live issue,
	// ErrInvalidIssue at IssueDiscussionsMax or for a bad id.
	LinkIssueDiscussion(ctx context.Context, tenant string, number int, task, by string, now time.Time) (bool, error)
	// UnlinkIssueDiscussion removes one link. ErrNotFound when the issue has
	// no such link, ErrIssueDiscussionLast when it is the last one.
	UnlinkIssueDiscussion(ctx context.Context, tenant string, number int, task string) error
	// TenantsMissingIssueBacklog: the tenants whose issues link to their
	// "Issue backlog" topic while it has no message, for the hub to post it.
	TenantsMissingIssueBacklog(ctx context.Context) ([]string, error)
	// TopicsByPrefix: at most limit topic ids of the tenant that start with
	// prefix (8 hex digits), for a brief that names a topic by its short id.
	TopicsByPrefix(ctx context.Context, tenant, prefix string, limit int) ([]string, error)
}

// TopicPrefixRe is a topic's short id: its first 8 hex digits.
var TopicPrefixRe = regexp.MustCompile(`^[0-9a-f]{8}$`)

var (
	_ IssueDiscussions = (*Memory)(nil)
	_ IssueDiscussions = (*Postgres)(nil)
)

// normDiscussions checks and de-duplicates a create's discussions, order
// kept: at least one, each a canonical uuid, at most IssueDiscussionsMax.
func normDiscussions(in []string) ([]string, error) {
	seen := map[string]bool{}
	out := []string{}
	for _, d := range in {
		d = strings.ToLower(strings.TrimSpace(d))
		if !canonUUIDRe.MatchString(d) {
			return nil, invalidIssue("discussion %q is not a topic id (a uuid)", d)
		}
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	switch {
	case len(out) == 0:
		return nil, invalidIssue("an issue must link to at least one discussion")
	case len(out) > IssueDiscussionsMax:
		return nil, invalidIssue("an issue links to at most %d discussions", IssueDiscussionsMax)
	}
	return out, nil
}

// --- Memory ------------------------------------------------------------------

// The memory store keeps the links and the rule; it does not relink on a
// message delete (the rdb 0194 trigger does that on Postgres).

func (m *memIssues) linksOf(tenant string, number int) []IssueDiscussion {
	return m.links[tenant][number]
}

func (m *memIssues) setLinks(tenant string, number int, ls []IssueDiscussion) {
	if m.links == nil {
		m.links = map[string]map[int][]IssueDiscussion{}
	}
	if m.links[tenant] == nil {
		m.links[tenant] = map[int][]IssueDiscussion{}
	}
	m.links[tenant][number] = ls
}

// IssueDiscussionLinks returns the discussion links of the given issues, by number (on the Memory store).
func (s *Memory) IssueDiscussionLinks(_ context.Context, tenant string, numbers []int) (map[int][]IssueDiscussion, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[int][]IssueDiscussion{}
	if numbers == nil {
		for n, ls := range s.iss.links[tenant] {
			out[n] = append([]IssueDiscussion{}, ls...)
		}
		return out, nil
	}
	for _, n := range numbers {
		if ls := s.iss.linksOf(tenant, n); len(ls) > 0 {
			out[n] = append([]IssueDiscussion{}, ls...)
		}
	}
	return out, nil
}

// DiscussionStates reports, per topic id, whether the discussion still exists and is open (on the Memory store).
func (s *Memory) DiscussionStates(_ context.Context, tenant string, tasks []string) (map[string]DiscussionState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]DiscussionState{}
	for _, task := range tasks {
		st := DiscussionState{State: DiscussionGone}
		var first *Message
		for k, m := range s.messages {
			if k[0] != tenant || (m.TaskID != task && m.MsgID != task) {
				continue
			}
			if st.State == DiscussionGone {
				st.State = DiscussionLive
			}
			if !m.ArchivedAt.IsZero() {
				st.State = DiscussionArchived
			}
			if m.TaskID == task && (first == nil || m.TS.Before(first.TS)) {
				first = m
			}
		}
		if first != nil {
			st.Channel, st.Title = first.Channel, discussionTitle(first.Body)
		}
		out[task] = st
	}
	return out, nil
}

// LinkIssueDiscussion links issue number to topic task; false when the link already existed (on the Memory store).
func (s *Memory) LinkIssueDiscussion(_ context.Context, tenant string, number int, task, by string, now time.Time) (bool, error) {
	if !canonUUIDRe.MatchString(task) {
		return false, invalidIssue("discussion %q is not a topic id (a uuid)", task)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	if _, ok := s.iss.rows[tenant][number]; !ok {
		return false, ErrNotFound
	}
	ls := s.iss.linksOf(tenant, number)
	for _, l := range ls {
		if l.TaskID == task {
			return false, nil
		}
	}
	if len(ls) >= IssueDiscussionsMax {
		return false, invalidIssue("an issue links to at most %d discussions", IssueDiscussionsMax)
	}
	s.iss.setLinks(tenant, number, append(append([]IssueDiscussion{}, ls...), IssueDiscussion{TaskID: task, LinkedBy: by, LinkedAt: now}))
	return true, nil
}

// UnlinkIssueDiscussion removes one link; the last link of an issue is refused (on the Memory store).
func (s *Memory) UnlinkIssueDiscussion(_ context.Context, tenant string, number int, task string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	ls := s.iss.linksOf(tenant, number)
	keep := []IssueDiscussion{}
	for _, l := range ls {
		if l.TaskID != task {
			keep = append(keep, l)
		}
	}
	switch {
	case len(keep) == len(ls):
		return ErrNotFound
	case len(keep) == 0:
		return ErrIssueDiscussionLast
	}
	s.iss.setLinks(tenant, number, keep)
	return nil
}

// TenantsMissingIssueBacklog lists the tenants whose issues link the Issue backlog topic while that topic is missing (on the Memory store).
func (s *Memory) TenantsMissingIssueBacklog(_ context.Context) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for tenant, byNum := range s.iss.links {
		id := IssueBacklogID(tenant)
		if _, ok := s.messages[[2]string{tenant, id}]; ok {
			continue
		}
	found:
		for _, ls := range byNum {
			for _, l := range ls {
				if l.TaskID == id {
					out = append(out, tenant)
					break found
				}
			}
		}
	}
	sort.Strings(out)
	return out, nil
}

// TopicsByPrefix lists up to limit topic ids of tenant that start with prefix (a short id) (on the Memory store).
func (s *Memory) TopicsByPrefix(_ context.Context, tenant, prefix string, limit int) ([]string, error) {
	if !TopicPrefixRe.MatchString(prefix) {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := map[string]bool{}
	out := []string{}
	for k, m := range s.messages {
		if k[0] == tenant && strings.HasPrefix(m.TaskID, prefix) && !seen[m.TaskID] {
			seen[m.TaskID] = true
			out = append(out, m.TaskID)
		}
	}
	sort.Strings(out)
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// discussionTitle is the first non-empty line of body, markdown emphasis and
// heading marks trimmed, at most 120 runes.
func discussionTitle(body string) string {
	for _, l := range strings.Split(body, "\n") {
		l = strings.TrimSpace(strings.Trim(strings.TrimSpace(l), "#*_> "))
		if l != "" {
			return cutTitle(l, 120)
		}
	}
	return ""
}

func cutTitle(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// --- Postgres ----------------------------------------------------------------

// issueDiscussionsInsertSQL links the issue just numbered in CreateIssue's
// batch: $1 tenant, $2 uuid[], $3 by, $4 at.
const issueDiscussionsInsertSQL = `INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by, linked_at)
	SELECT $1, (SELECT last_number FROM issue_counters WHERE tenant_id = $1), x, $3, $4 FROM unnest($2::uuid[]) AS x`

// IssueDiscussionLinks returns the discussion links of the given issues, by number (on Postgres).
func (s *Postgres) IssueDiscussionLinks(ctx context.Context, tenant string, numbers []int) (map[int][]IssueDiscussion, error) {
	out := map[int][]IssueDiscussion{}
	q := `SELECT number, task_id::text, linked_by, linked_at FROM issue_discussions WHERE tenant_id = $1`
	args := []any{tenant}
	if numbers != nil {
		q += ` AND number = ANY($2)`
		args = append(args, numbers)
	}
	err := s.queryTenant(ctx, tenant, q+` ORDER BY number, linked_at, task_id`, args, func(r pgx.Rows) error {
		var n int
		var d IssueDiscussion
		if err := r.Scan(&n, &d.TaskID, &d.LinkedBy, &d.LinkedAt); err != nil {
			return err
		}
		out[n] = append(out[n], d)
		return nil
	})
	return out, err
}

// discussionStatesSQL: per task, whether a message is left, whether one of
// them is archived, and the opening message's channel and body.
const discussionStatesSQL = `SELECT t.task::text,
		EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = $1 AND (m.task_id = t.task OR m.msg_id = t.task)),
		EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = $1 AND z.archived_at IS NOT NULL
			AND (z.msg_id = t.task OR z.task_id = t.task)),
		COALESCE(f.channel, ''), COALESCE(f.body, '')
	FROM unnest($2::uuid[]) AS t (task)
	LEFT JOIN LATERAL (SELECT m.channel, left(m.body, 2000) AS body FROM messages m
		WHERE m.tenant_id = $1 AND m.task_id = t.task ORDER BY m.ts, m.msg_id LIMIT 1) f ON true`

// DiscussionStates reports, per topic id, whether the discussion still exists and is open (on Postgres).
func (s *Postgres) DiscussionStates(ctx context.Context, tenant string, tasks []string) (map[string]DiscussionState, error) {
	out := map[string]DiscussionState{}
	ids := []string{}
	for _, t := range tasks {
		if canonUUIDRe.MatchString(t) {
			ids = append(ids, t)
		} else {
			out[t] = DiscussionState{State: DiscussionGone}
		}
	}
	if len(ids) == 0 {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, discussionStatesSQL, []any{tenant, ids}, func(r pgx.Rows) error {
		var task, channel, body string
		var live, archived bool
		if err := r.Scan(&task, &live, &archived, &channel, &body); err != nil {
			return err
		}
		st := DiscussionState{State: DiscussionGone}
		switch {
		case archived:
			st.State = DiscussionArchived
		case live:
			st.State = DiscussionLive
		}
		if st.State != DiscussionGone {
			st.Channel, st.Title = channel, discussionTitle(body)
		}
		out[task] = st
		return nil
	})
	return out, err
}

// LinkIssueDiscussion links issue number to topic task; false when the link already existed (on Postgres).
func (s *Postgres) LinkIssueDiscussion(ctx context.Context, tenant string, number int, task, by string, now time.Time) (bool, error) {
	if !canonUUIDRe.MatchString(task) {
		return false, invalidIssue("discussion %q is not a topic id (a uuid)", task)
	}
	added := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var n int
		err := tx.QueryRow(ctx, `SELECT count(d.task_id) FROM issues i
			LEFT JOIN issue_discussions d ON d.tenant_id = i.tenant_id AND d.number = i.number
			WHERE i.tenant_id = $1 AND i.number = $2 AND i.deleted_at IS NULL AND i.archived_at IS NULL
			GROUP BY i.number`, tenant, number).Scan(&n)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return ErrNotFound
		case err != nil:
			return err
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM issue_discussions WHERE tenant_id = $1 AND number = $2 AND task_id = $3)`,
			tenant, number, task).Scan(&exists); err != nil || exists {
			return err
		}
		if n >= IssueDiscussionsMax {
			return invalidIssue("an issue links to at most %d discussions", IssueDiscussionsMax)
		}
		tag, err := tx.Exec(ctx, `INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by, linked_at)
			VALUES ($1, $2, $3, $4, $5) ON CONFLICT (tenant_id, number, task_id) DO NOTHING`,
			tenant, number, task, by, now.UTC().Truncate(time.Microsecond))
		added = err == nil && tag.RowsAffected() == 1
		return err
	})
	return added, err
}

// UnlinkIssueDiscussion removes one link; the last link of an issue is refused (on Postgres).
func (s *Postgres) UnlinkIssueDiscussion(ctx context.Context, tenant string, number int, task string) error {
	if !canonUUIDRe.MatchString(task) {
		return ErrNotFound
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// The issue's links are locked, so two removes cannot each leave one.
		var n int
		var has bool
		if err := tx.QueryRow(ctx, `SELECT count(*), bool_or(task_id = $3) FROM (SELECT task_id FROM issue_discussions
			WHERE tenant_id = $1 AND number = $2 FOR UPDATE) d`, tenant, number, task).Scan(&n, &has); err != nil {
			return err
		}
		switch {
		case !has:
			return ErrNotFound
		case n <= 1:
			return ErrIssueDiscussionLast
		}
		_, err := tx.Exec(ctx, `DELETE FROM issue_discussions WHERE tenant_id = $1 AND number = $2 AND task_id = $3`, tenant, number, task)
		return err
	})
	return issueDiscussionErr(err)
}

// issueBacklogMissingSQL lists the tenants whose issues link the backlog
// topic while it has no row: each linking tenant once, its topic id computed
// before the probe (MATERIALIZED), so the probe is one primary-key read. With
// the id computed inside NOT EXISTS, RLS kept it off the index and every link
// filtered its tenant's messages (prd 2026-10-22, SPL-2868, n=3: 750 probes,
// 4 788 buffers, 174..238 ms -> 74, 10..14 ms; TestMissingHubCardsProbeByPrimaryKey).
const issueBacklogMissingSQL = `WITH d AS MATERIALIZED (
		SELECT DISTINCT tenant_id, spool_issue_backlog_id(tenant_id) AS id FROM issue_discussions
		WHERE task_id = spool_issue_backlog_id(tenant_id))
	SELECT d.tenant_id FROM d
	WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = d.tenant_id AND m.msg_id = d.id)
	ORDER BY d.tenant_id`

// TenantsMissingIssueBacklog lists the tenants whose issues link the Issue backlog topic while that topic is missing (on Postgres).
func (s *Postgres) TenantsMissingIssueBacklog(ctx context.Context) ([]string, error) {
	out := []string{}
	err := s.asOperatorQuery(ctx, issueBacklogMissingSQL, nil, func(r pgx.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		out = append(out, id)
		return nil
	})
	return out, err
}

// TopicsByPrefix reads the uuid range the prefix spans, so messages_task
// serves it.
func (s *Postgres) TopicsByPrefix(ctx context.Context, tenant, prefix string, limit int) ([]string, error) {
	out := []string{}
	if !TopicPrefixRe.MatchString(prefix) {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, `SELECT DISTINCT task_id::text FROM messages
		WHERE tenant_id = $1 AND task_id BETWEEN $2::uuid AND $3::uuid ORDER BY 1 LIMIT $4`,
		[]any{tenant, prefix + "-0000-0000-0000-000000000000", prefix + "-ffff-ffff-ffff-ffffffffffff", limit},
		func(r pgx.Rows) error {
			var id string
			if err := r.Scan(&id); err != nil {
				return err
			}
			out = append(out, id)
			return nil
		})
	return out, err
}

// issueDiscussionErr maps the 0194 rule's refusal at COMMIT.
func issueDiscussionErr(err error) error {
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.ConstraintName == "issue_discussions_at_least_one" {
		return fmt.Errorf("%w: %s", ErrIssueDiscussionLast, pe.Message)
	}
	return err
}
