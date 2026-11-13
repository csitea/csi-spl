package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// HumanLinks is human_links (rdb 0278, spec 042 "Note to self"; owner HUM-10,
// t1 df36f210, poll 3193d41f answer C: "Operator-set link only, no
// self-service"): two HUM ids that are one person. Only the operator route
// (human_links_operator.go, do_spl_human_link) writes it; the mention rule
// reads it: a person's tag of their own linked account is a note to self and
// gets no "does not belong to this channel" note.
type HumanLinks interface {
	// LinkHumans links a and b both ways; linking again changes nothing.
	// ErrNotFound when either is not a human, ErrTechnicalHuman when either
	// is an agent or a clone (Postgres), ErrSameHuman when a == b.
	LinkHumans(ctx context.Context, a, b, createdBy string, now time.Time) error
	// LinkedHumans is the HUM ids linked to hum, sorted; empty when none.
	LinkedHumans(ctx context.Context, hum string) ([]string, error)
}

// ErrSameHuman refuses linking a human to itself.
var ErrSameHuman = errors.New("a human is not linked to itself")

var (
	_ HumanLinks = (*Postgres)(nil)
	_ HumanLinks = (*Memory)(nil)
)

// LinkHumans implements HumanLinks: one row per direction, ON CONFLICT DO NOTHING.
func (s *Postgres) LinkHumans(ctx context.Context, a, b, createdBy string, now time.Time) error {
	if a == b {
		return ErrSameHuman
	}
	var n, technical int
	if err := s.pool.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE technical) FROM humans WHERE human_id = ANY($1::text[])`,
		[]string{a, b}).Scan(&n, &technical); err != nil {
		return err
	}
	switch {
	case n != 2:
		return ErrNotFound
	case technical != 0:
		return ErrTechnicalHuman
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO human_links (human_id, linked_human_id, created_by, created_at)
		VALUES ($1, $2, $3, $4), ($2, $1, $3, $4) ON CONFLICT DO NOTHING`, a, b, createdBy, now)
	return err
}

// LinkedHumans implements HumanLinks on human_links.
func (s *Postgres) LinkedHumans(ctx context.Context, hum string) ([]string, error) {
	out := []string{}
	rows, err := s.pool.Query(ctx, `SELECT linked_human_id FROM human_links WHERE human_id = $1 ORDER BY linked_human_id`, hum)
	if err != nil {
		return nil, err
	}
	out, err = pgx.AppendRows(out, rows, pgx.RowTo[string])
	return out, err
}

// LinkHumans implements HumanLinks in memory.
func (s *Memory) LinkHumans(_ context.Context, a, b, createdBy string, _ time.Time) error {
	if a == b {
		return ErrSameHuman
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	if h.humans[a] == nil || h.humans[b] == nil { // no technical flag here: Postgres only, as AddPendingEmail
		return ErrNotFound
	}
	for _, k := range [][2]string{{a, b}, {b, a}} {
		if _, ok := h.links[k]; !ok {
			h.links[k] = createdBy
		}
	}
	return nil
}

// LinkedHumans implements HumanLinks in memory.
func (s *Memory) LinkedHumans(_ context.Context, hum string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []string{}
	for k := range s.hum.links {
		if k[0] == hum {
			out = append(out, k[1])
		}
	}
	sort.Strings(out)
	return out, nil
}
