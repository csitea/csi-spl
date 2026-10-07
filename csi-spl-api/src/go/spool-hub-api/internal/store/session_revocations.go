package store

import (
	"context"
	"sort"
	"time"
)

// The admin password reset (owner HUM-10, t1 ea0af569) signs the member out
// everywhere: rdb 0147 session_revocations keeps one cut-off per human, and
// auth.revocations treats every session issued at or before it as dead. The
// hub admin route also needs to know HOW a member signs in, to tell a
// password account from an identity-provider-only one (SignIns).

// SignIn is one human_identities row of a human: the provider, and its
// subject (for ProviderNative, the password credential's e-mail).
type SignIn struct {
	Provider string `json:"provider"`
	Subject  string `json:"-"`
}

// RevokeSessions sets humanID's cut-off to at; a later cut-off wins.
// humans and session_revocations are hub-wide (outside rdb 0014's RLS).
func (s *Postgres) RevokeSessions(ctx context.Context, humanID string, at time.Time) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO session_revocations (human_id, revoked_at) VALUES ($1, $2)
		ON CONFLICT (human_id) DO UPDATE SET revoked_at = GREATEST(session_revocations.revoked_at, EXCLUDED.revoked_at)`,
		humanID, at)
	return err
}

// SessionRevocations answers every cut-off later than since.
func (s *Postgres) SessionRevocations(ctx context.Context, since time.Time) (map[string]time.Time, error) {
	rows, err := s.pool.Query(ctx, `SELECT human_id, revoked_at FROM session_revocations WHERE revoked_at > $1`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]time.Time{}
	for rows.Next() {
		var hum string
		var at time.Time
		if err := rows.Scan(&hum, &at); err != nil {
			return nil, err
		}
		out[hum] = at
	}
	return out, rows.Err()
}

// SignIns lists the sign-in identities of each human in ids, providers in
// name order; a human with none is absent from the map.
func (s *Postgres) SignIns(ctx context.Context, ids []string) (map[string][]SignIn, error) {
	out := map[string][]SignIn{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.pool.Query(ctx, `SELECT human_id, provider, subject FROM human_identities
		WHERE human_id = ANY($1) ORDER BY human_id, provider, subject`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var hum string
		var si SignIn
		if err := rows.Scan(&hum, &si.Provider, &si.Subject); err != nil {
			return nil, err
		}
		out[hum] = append(out[hum], si)
	}
	return out, rows.Err()
}

func (s *Memory) RevokeSessions(_ context.Context, humanID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.revokedAt == nil {
		s.revokedAt = map[string]time.Time{}
	}
	if at.After(s.revokedAt[humanID]) {
		s.revokedAt[humanID] = at
	}
	return nil
}

func (s *Memory) SessionRevocations(_ context.Context, since time.Time) (map[string]time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]time.Time{}
	for hum, at := range s.revokedAt {
		if at.After(since) {
			out[hum] = at
		}
	}
	return out, nil
}

func (s *Memory) SignIns(_ context.Context, ids []string) (map[string][]SignIn, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	want := map[string]bool{}
	for _, id := range ids {
		want[id] = true
	}
	out := map[string][]SignIn{}
	for k, i := range s.hum.identities {
		if want[i.human] {
			out[i.human] = append(out[i.human], SignIn{Provider: k[0], Subject: k[1]})
		}
	}
	for _, v := range out {
		sort.Slice(v, func(a, b int) bool {
			if v[a].Provider != v[b].Provider {
				return v[a].Provider < v[b].Provider
			}
			return v[a].Subject < v[b].Subject
		})
	}
	return out, nil
}
