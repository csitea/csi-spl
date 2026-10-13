package store

import (
	"context"
	"errors"
	"slices"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The per-agent sender allow-list (spec 044 FR-OS-017, T034, SPL-1018, rdb
// 0188). Owner HUM-10, t1 dee4081d, msg e9ec66fa: a workspace admin keeps,
// per agent, the members who may DM it or @mention it; an agent with no list
// takes messages from every member. A list is its own row, so an empty list
// (nobody) and no list (everybody) never read as each other.

// ErrSenderNotMember: a human id on a sender list is not a member of the workspace.
var ErrSenderNotMember = errors.New("store: not a member of this workspace")

// SenderList is one agent's list. Members are HUM ids, sorted.
type SenderList struct {
	Agent     string
	Members   []string
	UpdatedBy string
	UpdatedAt time.Time
}

// SenderAllow is implemented by stores that keep the allow-lists.
type SenderAllow interface {
	// SenderLists is every list of the workspace, by agent.
	SenderLists(ctx context.Context, tenant string) ([]SenderList, error)
	// SetSenderList replaces agent's list with members (none = nobody may
	// send). A member id that is not in the workspace is ErrSenderNotMember
	// and nothing is written.
	SetSenderList(ctx context.Context, tenant, agent string, members []string, by string, now time.Time) error
	// DropSenderList removes agent's list: every member may send it again.
	// ok = there was one.
	DropSenderList(ctx context.Context, tenant, agent string) (ok bool, err error)
	// SenderRefusedBy is the first of agents (sorted) that has a list not
	// naming sender, or "" when every one of them takes sender's message.
	SenderRefusedBy(ctx context.Context, tenant, sender string, agents []string) (string, error)
}

// SenderLists implements SenderAllow.
func (s *Postgres) SenderLists(ctx context.Context, tenant string) ([]SenderList, error) {
	var out []SenderList
	err := s.queryTenant(ctx, tenant, `SELECT l.agent_id, l.updated_by, l.updated_at,
		COALESCE(array_agg(a.human_id ORDER BY a.human_id) FILTER (WHERE a.human_id IS NOT NULL), '{}')
		FROM agent_sender_lists l
		LEFT JOIN agent_sender_allow a ON a.tenant_id = l.tenant_id AND a.agent_id = l.agent_id
		WHERE l.tenant_id = $1 GROUP BY l.agent_id, l.updated_by, l.updated_at ORDER BY l.agent_id`,
		[]any{tenant}, func(rows pgx.Rows) error {
			var l SenderList
			if err := rows.Scan(&l.Agent, &l.UpdatedBy, &l.UpdatedAt, &l.Members); err != nil {
				return err
			}
			l.UpdatedAt = l.UpdatedAt.UTC()
			out = append(out, l)
			return nil
		})
	return out, err
}

// SetSenderList implements SenderAllow: one transaction, the list row
// upserted and its members rewritten.
func (s *Postgres) SetSenderList(ctx context.Context, tenant, agent string, members []string, by string, now time.Time) error {
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO agent_sender_lists (tenant_id, agent_id, updated_by, updated_at)
			VALUES ($1, $2, $3, $4) ON CONFLICT (tenant_id, agent_id)
			DO UPDATE SET updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
			tenant, agent, by, now.UTC()); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM agent_sender_allow WHERE tenant_id = $1 AND agent_id = $2`,
			tenant, agent); err != nil {
			return err
		}
		if len(members) == 0 {
			return nil
		}
		_, err := tx.Exec(ctx, `INSERT INTO agent_sender_allow (tenant_id, agent_id, human_id, added_by, added_at)
			SELECT $1, $2, h, $4, $5 FROM unnest($3::text[]) AS h`, tenant, agent, members, by, now.UTC())
		return err
	})
	if pe := (*pgconn.PgError)(nil); errors.As(err, &pe) && pe.Code == "23503" {
		if pe.ConstraintName == "agent_sender_lists_tenant_id_fkey" {
			return ErrNotFound
		}
		return ErrSenderNotMember
	}
	return err
}

// DropSenderList implements SenderAllow; the members go with the list.
func (s *Postgres) DropSenderList(ctx context.Context, tenant, agent string) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM agent_sender_lists WHERE tenant_id = $1 AND agent_id = $2`,
		tenant, agent)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// SenderRefusedBy implements SenderAllow: primary-key probes of the agents a
// send names, nothing read when none of them has a list.
func (s *Postgres) SenderRefusedBy(ctx context.Context, tenant, sender string, agents []string) (string, error) {
	if len(agents) == 0 {
		return "", nil
	}
	var out string
	err := s.queryTenant(ctx, tenant, `SELECT l.agent_id FROM agent_sender_lists l
		WHERE l.tenant_id = $1 AND l.agent_id = ANY($2)
		  AND NOT EXISTS (SELECT 1 FROM agent_sender_allow a
		                  WHERE a.tenant_id = l.tenant_id AND a.agent_id = l.agent_id AND a.human_id = $3)
		ORDER BY l.agent_id LIMIT 1`, []any{tenant, agents, sender}, func(rows pgx.Rows) error {
		return rows.Scan(&out)
	})
	return out, err
}

// memSenderList is one list of the in-memory store.
type memSenderList struct {
	members   map[string]bool
	updatedBy string
	updatedAt time.Time
}

// senderListLocked is the (tenant, agent) list with the members that are
// still in the workspace (rdb 0188's membership cascade); s.mu is held.
func (s *Memory) senderListLocked(k [2]string) (SenderList, bool) {
	l, ok := s.senders[k]
	if !ok {
		return SenderList{}, false
	}
	out := SenderList{Agent: k[1], Members: []string{}, UpdatedBy: l.updatedBy, UpdatedAt: l.updatedAt}
	for h := range l.members {
		if _, in := s.hum.members[[2]string{k[0], h}]; in {
			out.Members = append(out.Members, h)
		}
	}
	sort.Strings(out.Members)
	return out, true
}

// SenderLists implements SenderAllow for the in-memory store.
func (s *Memory) SenderLists(_ context.Context, tenant string) ([]SenderList, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []SenderList
	for k := range s.senders {
		if k[0] == tenant {
			l, _ := s.senderListLocked(k)
			out = append(out, l)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Agent < out[j].Agent })
	return out, nil
}

// SetSenderList implements SenderAllow for the in-memory store.
func (s *Memory) SetSenderList(_ context.Context, tenant, agent string, members []string, by string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := memSenderList{members: map[string]bool{}, updatedBy: by, updatedAt: now.UTC()}
	for _, h := range members {
		if _, in := s.hum.members[[2]string{tenant, h}]; !in {
			return ErrSenderNotMember
		}
		l.members[h] = true
	}
	if s.senders == nil {
		s.senders = map[[2]string]memSenderList{}
	}
	s.senders[[2]string{tenant, agent}] = l
	return nil
}

// DropSenderList implements SenderAllow for the in-memory store.
func (s *Memory) DropSenderList(_ context.Context, tenant, agent string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, agent}
	_, ok := s.senders[k]
	delete(s.senders, k)
	return ok, nil
}

// SenderRefusedBy implements SenderAllow for the in-memory store.
func (s *Memory) SenderRefusedBy(_ context.Context, tenant, sender string, agents []string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sorted := slices.Clone(agents)
	sort.Strings(sorted)
	for _, a := range sorted {
		l, ok := s.senderListLocked([2]string{tenant, a})
		if ok && !slices.Contains(l.Members, sender) {
			return a, nil
		}
	}
	return "", nil
}
