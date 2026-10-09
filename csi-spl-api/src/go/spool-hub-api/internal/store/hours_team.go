package store

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"
)

// The team side of hours tracking (spec 107 v1.0, T008 / T009; sections 4.4,
// 6.1, 6.2): every member's APPROVED entries, for a holder of hours.read.
//
// Privacy (spec 1.7): this read never returns a rejected entry, a raw minute
// or a suggestion; it names hours_entries only.

// HoursTeamEntry is one approved hours_entries row with its member.
type HoursTeamEntry struct {
	Member string
	HoursEntry
}

// HoursTeam is implemented by Memory and Postgres.
type HoursTeam interface {
	// HoursApprovedEntries is the approved entries of days from..to
	// (inclusive); member "" = every member. By member, day, then target.
	HoursApprovedEntries(ctx context.Context, tenant, member, from, to string) ([]HoursTeamEntry, error)
}

var (
	_ HoursTeam = (*Memory)(nil)
	_ HoursTeam = (*Postgres)(nil)
)

func sortHoursTeamEntries(out []HoursTeamEntry) {
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Member != b.Member {
			return a.Member < b.Member
		}
		if a.Day != b.Day {
			return a.Day < b.Day
		}
		return a.Target < b.Target
	})
}

func (s *Memory) HoursApprovedEntries(_ context.Context, tenant, member, from, to string) ([]HoursTeamEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []HoursTeamEntry{}
	for k, rows := range s.hrs.entries {
		if k[0] != tenant || (member != "" && k[1] != member) {
			continue
		}
		for _, e := range rows {
			if e.State == HoursApproved && from <= e.Day && e.Day <= to {
				out = append(out, HoursTeamEntry{Member: k[1], HoursEntry: e})
			}
		}
	}
	sortHoursTeamEntries(out)
	return out, nil
}

func (s *Postgres) HoursApprovedEntries(ctx context.Context, tenant, member, from, to string) ([]HoursTeamEntry, error) {
	out := []HoursTeamEntry{}
	err := s.queryTenant(ctx, tenant, `SELECT member_id, day::text, target, minutes, suggested_minutes, state,
			coalesce(note, ''), updated_at, updated_by
		FROM hours_entries
		WHERE tenant_id = $1 AND ($2 = '' OR member_id = $2) AND state = 'approved'
			AND day BETWEEN $3::date AND $4::date
		ORDER BY member_id, day, target`, []any{tenant, member, from, to}, func(r pgx.Rows) error {
		var e HoursTeamEntry
		if err := r.Scan(&e.Member, &e.Day, &e.Target, &e.Minutes, &e.SuggestedMinutes, &e.State,
			&e.Note, &e.UpdatedAt, &e.UpdatedBy); err != nil {
			return err
		}
		e.UpdatedAt = e.UpdatedAt.UTC()
		out = append(out, e)
		return nil
	})
	return out, err
}
